//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// What the hook does with a lookup it can answer: prints the answer where the refusal would have been, records it as the index serving the context, and keeps every promise a refusal makes.
@Suite(.temporaryDirectories)
struct InPlaceHookTests {
    private static var command: String {
        #"grep -n 'static\|case ' Sources/App/Depot.swift"#
    }

    private static func respond(
        _ lookup: PreToolUseCommand.Lookup,
        in stores: Stores,
        payload: [String: Any] = ["agent_id": "a1"],
        answerer: (InPlaceShape.Match, Bool) -> InPlaceAnswerer.Outcome
    ) -> String? {
        PreToolUseCommand.respond(
            to: lookup,
            session: "s1",
            context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: payload["agent_id"] as? String),
            payload: payload,
            cwd: "/repo",
            ledger: stores.ledger,
            usage: UsageLog(fileURL: stores.usageLog),
            suppressions: SuppressionLog(fileURL: stores.suppressionLog),
            answerer: { match, gone, _ in answerer(match, gone) }
        )
    }

    /// The denial's reason out of what the hook printed.
    private static func reason(of output: String?, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let data = try #require(output.map { Data($0.utf8) }, sourceLocation: sourceLocation)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any], sourceLocation: sourceLocation)
        let specific = try #require(object["hookSpecificOutput"] as? [String: Any], sourceLocation: sourceLocation)
        #expect(specific["permissionDecision"] as? String == "deny", sourceLocation: sourceLocation)
        return try #require(specific["permissionDecisionReason"] as? String, sourceLocation: sourceLocation)
    }

    /// The lookup the hook classifies `command` as, from a directory with no index behind it.
    private static func lookup(sourceLocation: SourceLocation = #_sourceLocation) throws -> PreToolUseCommand.Lookup {
        try #require(try PreToolUseCommand.lookup(
            command: command,
            payload: [:],
            in: "/repo",
            noting: SuppressionLog(fileURL: TemporaryDirectory.make("ignored").appendingPathComponent("ignored.jsonl")),
            couldAnswer: { _, _ in true }
        ), sourceLocation: sourceLocation)
    }

    /// An answer is printed in the refusal's place and recorded as the index serving this context: the usage line the server would have written, marked as the hook's, which is what the saving is priced from and what excuses a whole read of the file afterwards.
    @Test
    func anAnswerIsPrintedAndRecordedAsTheIndexServingTheContext() throws {
        let stores = try Stores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }
        let answered = InPlaceAnswerer.Answered(
            reason: "sift answered this with `digest Sources/App/Depot.swift` …",
            calls: [InPlaceAnswerer.Call(tool: "digest", target: "Sources/App/Depot.swift", bytes: AnswerBytes(served: 300, source: 3000))],
            root: "/repo",
            milliseconds: 80
        )
        let lookup = try Self.lookup()

        let output = Self.respond(lookup, in: stores) { match, gone in
            if case .declarations(file: "Sources/App/Depot.swift", _) = match.call {} else {
                Issue.record("expected the file's declarations, got \(match.call)")
            }
            #expect(match.directory == "/repo")
            #expect(match.isWholeCommand)
            #expect(!gone)
            return .answered(answered)
        }
        let line = try #require(stores.lines(of: stores.usageLog).first)

        #expect(try Self.reason(of: output) == answered.reason)
        #expect(line["tool"] as? String == "digest")
        #expect(line["target"] as? String == "Sources/App/Depot.swift")
        #expect(line["session"] as? String == "s1")
        #expect(line["agent"] as? String == "a1")
        #expect(line["via"] as? String == "hook")
        #expect(line["outBytes"] as? Int == 300)
        #expect(line["srcBytes"] as? Int == 3000)
        // The identical re-run is let through on the ledger's record, as after any refusal.
        #expect(Self.respond(lookup, in: stores) { _, _ in .withheld(.failed) } == nil)
    }

    /// An answer withheld lets the command through and leaves a record of why, so a budget that bites shows in a rate.
    ///
    /// Nothing is printed: the bare refusal the withholding used to fall back on cost a round trip worth several times the call it named, so what is left where no answer can be given is the command running as it would have anyway. The note is the whole of what the hook takes from the attempt.
    @Test
    func aWithheldAnswerLetsTheCommandThroughAndRecordsWhy() throws {
        let stores = try Stores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }

        let output = try Self.respond(Self.lookup(), in: stores) { _, _ in .withheld(.overTime) }
        let suppression = try #require(stores.lines(of: stores.suppressionLog).first)

        #expect(output == nil)
        #expect(stores.lines(of: stores.usageLog).isEmpty)
        #expect(suppression["rule"] as? String == "answerWithheld")
        #expect(suppression["symbol"] as? String == InPlaceAnswerer.Withholding.overTime.rawValue)
    }

    /// A window the real answerer withholds as `notSmaller` is logged under the call's `tool_use_id`, which is how the audit finds that verdict again for that call.
    @Test
    func aWindowWithheldAsNotSmallerIsLoggedUnderItsCall() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let stores = try Stores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }
        let backoff = try InPlaceAnswerTests.backoff()

        let output = await InPlaceAnswerTests.onItsOwnThread { () -> String? in
            let command = "sed -n 100,119p Sources/App/Depot.swift"
            let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": command], "session_id": "s1", "tool_use_id": "toolu_window"]
            guard let lookup = PreToolUseCommand.lookup(
                command: command,
                payload: payload,
                in: root.path,
                noting: SuppressionLog(fileURL: stores.suppressionLog),
                couldAnswer: { _, _ in true }
            ) else {
                return "no lookup"
            }
            return PreToolUseCommand.respond(
                to: lookup,
                session: "s1",
                context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil),
                payload: payload,
                cwd: root.path,
                ledger: stores.ledger,
                usage: UsageLog(fileURL: stores.usageLog),
                suppressions: SuppressionLog(fileURL: stores.suppressionLog),
                answerer: { match, gone, _ in InPlaceAnswerer.answer(match.call, from: match.directory, serverGone: gone, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff) }
            )
        }
        let suppression = try #require(stores.lines(of: stores.suppressionLog).first)

        #expect(output == nil)
        #expect(suppression["rule"] as? String == "answerWithheld")
        #expect(suppression["symbol"] as? String == InPlaceAnswerer.Withholding.notSmaller.rawValue)
        #expect(suppression["call"] as? String == "toolu_window")
    }

    /// The ledger decides first: where it lets a command through, nothing is answered and nothing is run.
    @Test
    func theLedgerDecidesBeforeAnythingIsAnswered() throws {
        let stores = try Stores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }
        let lookup = try Self.lookup()
        let answered = InPlaceAnswerer.Answered(
            reason: "answered",
            calls: [InPlaceAnswerer.Call(tool: "digest", target: "Sources/App/Depot.swift", bytes: AnswerBytes(served: 1, source: 2))],
            root: "/repo",
            milliseconds: 1
        )
        _ = Self.respond(lookup, in: stores) { _, _ in .answered(answered) }
        var asked = false

        let rerun = Self.respond(lookup, in: stores) { _, _ in
            asked = true
            return .withheld(.notExact)
        }

        #expect(rerun == nil)
        #expect(!asked)
    }

    /// End to end on a real index: a whole read of a Swift file is answered with its digest, and the answer's line lands in the usage log under the session.
    @Test
    func aWholeReadIsAnsweredWithItsDigestEndToEnd() async throws {
        let root = try await WorthAnsweringFixture.repository()
        let stores = try Stores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }
        let file = root.appendingPathComponent("Sources/App/Depot.swift").path
        // Made here rather than in the answerer: that runs on a thread of its own, which the test's scope does not reach.
        let backoff = try InPlaceAnswerTests.backoff()

        // On a thread of its own, as the hook runs on its process's main thread (`InPlaceAnswerTests.answer`).
        let output = await InPlaceAnswerTests.onItsOwnThread { () -> String? in
            let payload: [String: Any] = ["tool_name": "Read", "tool_input": ["file_path": file], "session_id": "s1"]
            guard let lookup = PreToolUseCommand.lookup(
                command: nil,
                payload: payload,
                in: root.path,
                noting: SuppressionLog(fileURL: stores.suppressionLog),
                digested: DigestedFiles(usageLog: stores.usageLog),
                couldAnswer: { _, _ in true }
            ) else {
                return nil
            }
            return PreToolUseCommand.respond(
                to: lookup,
                session: "s1",
                context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil),
                payload: payload,
                cwd: root.path,
                ledger: stores.ledger,
                usage: UsageLog(fileURL: stores.usageLog),
                suppressions: SuppressionLog(fileURL: stores.suppressionLog),
                // The real answerer, with room for a machine loaded by the rest of the suite: this is about what the
                // hook does with an answer, and the budget has a test of its own.
                answerer: { match, gone, _ in InPlaceAnswerer.answer(match.call, from: match.directory, serverGone: gone, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff) }
            )
        }
        let reason = try Self.reason(of: output)

        #expect(reason.hasPrefix("sift answered this with `digest Sources/App/Depot.swift` instead of running it"))
        #expect(reason.contains("struct Depot"))
        #expect(stores.lines(of: stores.usageLog).first?["via"] as? String == "hook")
        // And the context now holds the digest, so a whole read of the same file is let through.
        #expect(DigestedFiles(usageLog: stores.usageLog).contains(file, session: "s1", agent: nil))
    }

    /// An `awk 1 F` whole read reaches the answer through the hook's own lookup classification — not only through `InPlaceShape.match` called directly, which a bare number's own reading (``ShellQuery``'s `operands`) used to leave no reader stage for at all.
    @Test(arguments: ["awk 1 Sources/App/Depot.swift", "awk 1 Sources/App/Depot.swift | head -500"])
    func anAwkBareNumberWholeReadIsAnsweredThroughTheHook(command: String) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: InPlaceAnswerTests.pastTheFloor)
        let stores = try Stores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }
        let backoff = try InPlaceAnswerTests.backoff()

        let output = await InPlaceAnswerTests.onItsOwnThread { () -> String? in
            guard let lookup = PreToolUseCommand.lookup(
                command: command,
                payload: [:],
                in: root.path,
                noting: SuppressionLog(fileURL: stores.suppressionLog),
                digested: DigestedFiles(usageLog: stores.usageLog),
                couldAnswer: { _, _ in true }
            ) else {
                return nil
            }
            return PreToolUseCommand.respond(
                to: lookup,
                session: "s1",
                context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil),
                payload: [:],
                cwd: root.path,
                ledger: stores.ledger,
                usage: UsageLog(fileURL: stores.usageLog),
                suppressions: SuppressionLog(fileURL: stores.suppressionLog),
                answerer: { match, gone, _ in InPlaceAnswerer.answer(match.call, from: match.directory, serverGone: gone, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff) }
            )
        }
        let reason = try Self.reason(of: output)

        #expect(reason.contains("struct Depot"))
    }

    /// Driven through the built binary with `SIFT_USAGE_LOG` and `SIFT_ADVICE_DIR` set, the hook writes where they point and nothing under the home directory — whichever way the time budget falls on a loaded machine.
    @Test
    func theBinaryWritesOnlyWhereTheOverridesPoint() async throws {
        let binary = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)")
        let root = try await InPlaceAnswerTests.indexedRepository()
        let scratch = try TemporaryDirectory.make("overrides").appendingPathComponent("overrides")
        let home = scratch.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let usageLog = scratch.appendingPathComponent("usage.jsonl")
        let advice = scratch.appendingPathComponent("advice")
        let payload: [String: Any] = [
            "session_id": "s-overrides", "cwd": root.path, "hook_event_name": "PreToolUse", "tool_name": "Read",
            "tool_input": ["file_path": root.appendingPathComponent("Sources/App/Depot.swift").path],
        ]

        let process = Process()
        process.executableURL = binary
        process.arguments = ["pre-tool-use"]
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = home.path
        environment["SIFT_USAGE_LOG"] = usageLog.path
        environment["SIFT_ADVICE_DIR"] = advice.path
        environment["CLAUDE_CODE_SESSION_ID"] = nil
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        try input.fileHandleForWriting.write(JSONSerialization.data(withJSONObject: payload))
        input.fileHandleForWriting.closeFile()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stores = try Stores()
        // Answered, the hook prints the denial and the usage line is where the override points; withheld over
        // the budget, it prints nothing at all — the call goes through — and the note of why is where the
        // override points instead.
        let recordedWhereOverridden: Bool
        if printed.isEmpty {
            recordedWhereOverridden = stores.lines(of: advice.appendingPathComponent("suppressions.jsonl"))
                .first?["rule"] as? String == "answerWithheld"
        } else {
            let reason = try Self.reason(of: String(data: printed, encoding: .utf8))
            recordedWhereOverridden = reason.hasPrefix("sift answered this with")
                && stores.lines(of: usageLog).first?["via"] as? String == "hook"
        }

        #expect(recordedWhereOverridden)
        #expect(FileManager.default.fileExists(atPath: advice.path))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".sift/usage.jsonl").path))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".sift/advice").path))
    }

    /// Driven through the built binary with no `SIFT_USAGE_LOG`, the hook logs an answer only for a payload whose transcript file exists, so a probe piped in by hand leaves the shared log alone.
    @Test
    func aHandPipedProbeLeavesNoUsageLine() async throws {
        let binary = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)")
        let root = try await WorthAnsweringFixture.repository()
        let scratch = try TemporaryDirectory.make("probe").appendingPathComponent("probe")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let transcript = scratch.appendingPathComponent("transcript.jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        let stores = try Stores()

        func hookLines(transcriptPath: String, home name: String) throws -> (printed: Bool, lines: Int) {
            let home = scratch.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let payload: [String: Any] = [
                "session_id": "s-\(name)", "cwd": root.path, "hook_event_name": "PreToolUse", "tool_name": "Read",
                "transcript_path": transcriptPath,
                "tool_input": ["file_path": root.appendingPathComponent("Sources/App/Depot.swift").path],
            ]
            let process = Process()
            process.executableURL = binary
            process.arguments = ["pre-tool-use"]
            var environment = ProcessInfo.processInfo.environment
            environment["CFFIXED_USER_HOME"] = home.path
            environment["SIFT_USAGE_LOG"] = nil
            environment["SIFT_ADVICE_DIR"] = home.appendingPathComponent("advice").path
            environment["CLAUDE_CODE_SESSION_ID"] = nil
            process.environment = environment
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            try input.fileHandleForWriting.write(JSONSerialization.data(withJSONObject: payload))
            input.fileHandleForWriting.closeFile()
            let printed = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let hooks = stores.lines(of: home.appendingPathComponent(".sift/usage.jsonl")).filter { $0["via"] as? String == "hook" }
            return (!printed.isEmpty && String(data: printed, encoding: .utf8)?.contains("sift answered this with") == true, hooks.count)
        }

        let probe = try hookLines(transcriptPath: "/nonexistent", home: "probe-home")
        let real = try hookLines(transcriptPath: transcript.path, home: "real-home")

        #expect(probe.lines == 0)
        // Withheld over the budget, the hook answers nothing and logs nothing; answered, it logs exactly one line.
        #expect(real.lines == (real.printed ? 1 : 0))
        #expect(real.printed)
    }
}

private extension InPlaceHookTests {
    /// Everything the hook writes, somewhere this test owns.
    struct Stores {
        let directory: URL

        init() throws {
            directory = try TemporaryDirectory.make("inplace").appendingPathComponent("inplace")
        }

        var ledger: AdviceLedger {
            AdviceLedger(directory: directory.appendingPathComponent("advice"))
        }

        var usageLog: URL {
            directory.appendingPathComponent("usage.jsonl")
        }

        var suppressionLog: URL {
            directory.appendingPathComponent("suppressions.jsonl")
        }

        func lines(of url: URL) -> [[String: Any]] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
    }
}
