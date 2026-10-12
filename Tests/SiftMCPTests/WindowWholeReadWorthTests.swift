//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A window that prints most of a Swift file pays the same second turn as a whole read of it, so it is weighed as the whole read is: let through as `notWorthTheTurn` where the digest spares less than that turn, answered where it spares more.
///
/// A narrower window keeps the window rules alone.
@Suite(.temporaryDirectories)
struct WindowWholeReadWorthTests {
    // MARK: - Through the answerer

    /// A repository whose `Depot` is 178 lines long and small enough that a whole read of it is not worth the turn at the default context.
    private static func smallRepository() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let members = (1 ... 35).map { index in
            "    func stock\(index)() -> Int {\n        let count = \(index)\n        let doubled = count * 2\n        return doubled + count\n    }"
        }
        try ("/// A depot.\nstruct Depot {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent("Sources/App/Depot.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// The hook's verdict line for the payload `made` builds, answered by the real answerer against `root`.
    private static func decide(_ made: @escaping @Sendable () -> [String: Any], in root: URL) async throws -> String {
        let backoff = try InPlaceAnswerTests.backoff()
        let advice = try TemporaryDirectory.make("advice")
        let usage = try TemporaryDirectory.make("usage").appendingPathComponent("usage.jsonl")
        let log = try TemporaryDirectory.make("suppressions").appendingPathComponent("suppressions.jsonl")
        return await InPlaceAnswerTests.onItsOwnThread { () -> String in
            let payload = made()
            let command = (payload["tool_input"] as? [String: Any])?["command"] as? String
            guard let lookup = PreToolUseCommand.lookup(command: command, payload: payload, in: root.path, noting: SuppressionLog(fileURL: log), couldAnswer: { _, _ in true }) else {
                return "no lookup"
            }
            return PreToolUseCommand.outcome(
                to: lookup,
                session: "s1",
                context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil),
                payload: payload,
                command: command,
                cwd: root.path,
                ledger: AdviceLedger(directory: advice),
                usage: UsageLog(fileURL: usage),
                suppressions: SuppressionLog(fileURL: log),
                answerer: { match, gone, _ in InPlaceAnswerer.answer(match, serverGone: gone, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff) },
                serverPresence: { _, _ in false }
            ).verdict.line
        }
    }

    private static func bash(_ command: String) -> [String: Any] {
        ["tool_name": "Bash", "tool_input": ["command": command], "session_id": "s1", "tool_use_id": "toolu_window"]
    }

    private static func read(_ root: URL, offset: Int, limit: Int) -> [String: Any] {
        let path = root.appendingPathComponent("Sources/App/Depot.swift").path
        return ["tool_name": "Read", "tool_input": ["file_path": path, "offset": offset, "limit": limit], "session_id": "s1", "tool_use_id": "toolu_window"]
    }

    /// The control: the whole read of the 178-line file is let through on worth, so the windows below are judged against a read the rule lets run.
    @Test(arguments: ["cat Sources/App/Depot.swift", "cat -n Sources/App/Depot.swift"])
    func theWholeReadIsLetThroughOnWorth(command: String) async throws {
        let root = try await Self.smallRepository()

        let verdict = try await Self.decide({ Self.bash(command) }, in: root)

        #expect(verdict == "allowed\t\tnotWorthTheTurn", "\(verdict)")
    }

    /// The control for the `Read` tool: a `Read` given no range is let through on worth.
    @Test
    func theWholeReadToolCallIsLetThroughOnWorth() async throws {
        let root = try await Self.smallRepository()
        let path = root.appendingPathComponent("Sources/App/Depot.swift").path

        let verdict = try await Self.decide({ ["tool_name": "Read", "tool_input": ["file_path": path], "session_id": "s1", "tool_use_id": "toolu_window"] }, in: root)

        #expect(verdict == "allowed\t\tnotWorthTheTurn", "\(verdict)")
    }

    /// A window reaching to or past the file's end is the whole read under another spelling, and is let through as it is.
    @Test(arguments: ["sed -n '1,200p' Sources/App/Depot.swift", "sed -n '1,178p' Sources/App/Depot.swift", "head -n 200 Sources/App/Depot.swift", "head -n 178 Sources/App/Depot.swift"])
    func aWindowCoveringTheFileIsLetThroughOnWorth(command: String) async throws {
        let root = try await Self.smallRepository()

        let verdict = try await Self.decide({ Self.bash(command) }, in: root)

        #expect(verdict == "allowed\t\tnotWorthTheTurn", "\(verdict)")
    }

    /// A `Read` whose range covers the file is let through as the whole `Read` is.
    @Test
    func aRangedReadCoveringTheFileIsLetThroughOnWorth() async throws {
        let root = try await Self.smallRepository()

        let verdict = try await Self.decide({ Self.read(root, offset: 1, limit: 200) }, in: root)

        #expect(verdict == "allowed\t\tnotWorthTheTurn", "\(verdict)")
    }

    /// A file large enough that its digest pays for the turn is still answered through a window covering it.
    @Test(arguments: ["sed -n '1,250p' Sources/App/Depot.swift", "head -n 250 Sources/App/Depot.swift"])
    func aCoveringWindowOnALargeFileIsAnswered(command: String) async throws {
        let root = try await WorthAnsweringFixture.repository()

        let verdict = try await Self.decide({ Self.bash(command) }, in: root)

        #expect(verdict.hasPrefix("in-place"), "\(verdict)")
    }

    // MARK: - The share of the file

    /// A file of exactly 100 lines on disk, so the share a window prints is its line count in hundredths.
    private static func hundredLineFile() throws -> URL {
        let directory = try TemporaryDirectory.make("window-worth")
        let file = directory.appendingPathComponent("Depot.swift")
        try ((1 ... 100).map { "// line \($0)" }.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// The verdict for `command`, every lookup answered with a digest of `served` bytes standing in for `source`.
    private static func judged(_ command: String, in directory: URL, answers served: Int, of source: Int, sourceLocation: SourceLocation = #_sourceLocation) throws -> PreToolUseCommand.Verdict {
        let scratch = try TemporaryDirectory.make("window-worth-hook")
        let suppressions = SuppressionLog(fileURL: scratch.appendingPathComponent("suppressions.jsonl"))
        let payload = bash(command)
        let lookup = try #require(PreToolUseCommand.lookup(command: command, payload: payload, in: directory.path, noting: suppressions, couldAnswer: { _, _ in true }), sourceLocation: sourceLocation)
        let target = directory.appendingPathComponent("Depot.swift").path
        let reason = "sift answered this with `digest \(target)` instead of running it\(InPlaceAnswer.openingSuffix)\n\nbody"
        let call = InPlaceAnswerer.Call(tool: "digest", target: target, bytes: AnswerBytes(served: served, source: source))
        let answered = InPlaceAnswerer.Outcome.answered(InPlaceAnswerer.Answered(reason: reason, calls: [call], root: directory.path, milliseconds: 1, wholeRead: call.bytes))
        return PreToolUseCommand.outcome(
            to: lookup,
            session: "s1",
            context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: nil),
            payload: payload,
            command: command,
            cwd: directory.path,
            ledger: AdviceLedger(directory: scratch.appendingPathComponent("advice")),
            usage: UsageLog(fileURL: scratch.appendingPathComponent("usage.jsonl")),
            suppressions: suppressions,
            answerer: { _, _, _ in answered }
        ).verdict
    }

    /// Three quarters of the file's lines is the share at which a window is weighed: 75 of the 100 lines are, 74 are not, whatever spelling or windows print them.
    @Test(arguments: [
        ("sed -n 1,75p Depot.swift", "notWorthTheTurn"),
        ("sed -n 26,100p Depot.swift", "notWorthTheTurn"),
        ("sed -n '1,40p;61,95p' Depot.swift", "notWorthTheTurn"),
        ("sed -n 20,500p Depot.swift", "notWorthTheTurn"),
        ("head -n 75 Depot.swift", "notWorthTheTurn"),
        ("sed -n 1,74p Depot.swift", nil),
        ("sed -n 27,100p Depot.swift", nil),
        ("sed -n '1,40p;61,94p' Depot.swift", nil),
        ("head -n 74 Depot.swift", nil),
    ] as [(String, String?)])
    func aWindowIsWeighedFromThreeQuartersOfTheFile(command: String, rule: String?) throws {
        let file = try Self.hundredLineFile()

        let verdict = try Self.judged(command, in: file.deletingLastPathComponent(), answers: 1000, of: 4000)

        if let rule {
            #expect(verdict.token == "allowed" && verdict.rule == rule, "\(verdict.line)")
        } else {
            #expect(verdict.token == "in-place", "\(verdict.line)")
        }
    }

    /// A covering window whose digest spares more than the turn costs is answered, as the whole read would be.
    @Test
    func aCoveringWindowWorthTheTurnIsAnswered() throws {
        let file = try Self.hundredLineFile()

        let verdict = try Self.judged("sed -n 1,100p Depot.swift", in: file.deletingLastPathComponent(), answers: 8000, of: 40000)

        #expect(verdict.token == "in-place", "\(verdict.line)")
    }

    // MARK: - A window answered with members weighs as the whole read does

    /// A repository whose `Depot` nests `inner` structs, each a func padded by a comment of `padding` characters, a one-line func and a computed var, so the whole digest names the nested members on their type's line alone and a window is answered with the members it overlaps instead.
    private static func nestedRepository(inner: Int, padding: Int) async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let structs = (1 ... inner).map { index in
            "    struct Orchard\(index) {\n        // \(String(repeating: "w", count: padding))\n        func padded\(index)() -> Int { \(index) }\n        func short\(index)() -> Int { \(index) }\n        var value\(index): Int { \(index) }\n    }"
        }
        try ("/// A depot.\nenum Depot {\n" + structs.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent("Sources/App/Depot.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// Whether the whole digest is worth the turn decides every window covering the file: the members answering them are larger than the digest and the window prints less than the file, and the whole read's own inputs weigh instead.
    @Test(arguments: ["cat Sources/App/Depot.swift", "sed -n 3,200p Sources/App/Depot.swift", "sed -n '3,50p;52,200p' Sources/App/Depot.swift"])
    func aCoveringWindowOnANestedFileWorthTheTurnIsAnswered(command: String) async throws {
        let root = try await Self.nestedRepository(inner: 12, padding: 710)

        let verdict = try await Self.decide({ Self.bash(command) }, in: root)

        #expect(verdict.hasPrefix("in-place"), "\(verdict)")
    }

    /// A nested file whose whole read is let through on worth lets its covering windows through too.
    @Test(arguments: ["cat Sources/App/Depot.swift", "sed -n 3,200p Sources/App/Depot.swift", "sed -n '3,50p;52,200p' Sources/App/Depot.swift"])
    func aCoveringWindowOnANestedFileBelowTheMarginIsLetThrough(command: String) async throws {
        let root = try await Self.nestedRepository(inner: 12, padding: 670)

        let verdict = try await Self.decide({ Self.bash(command) }, in: root)

        #expect(verdict == "allowed\t\tnotWorthTheTurn", "\(verdict)")
    }

    // MARK: - Above the size budget, where the whole read is served its cut page

    private static var cutPath: String {
        "Sources/App/Cut.swift"
    }

    /// A repository whose `Cut`, below an `import`, holds ten funcs of forty padded body lines, then fifty one-line funcs with fifteen-parameter signatures: 484 lines of 40 kB, whose whole digest runs past the size budget, so a whole read of it is served its first page cut to fit — as is a window over the `import`, whose members are never served.
    private static func cutRepository() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let long = (1 ... 10).map { index in
            "    func long\(index)() -> Int {\n" + (1 ... 40).map { line in "        let value\(line) = \(line) // \(String(repeating: "p", count: 40))" }.joined(separator: "\n") + "\n        return \(index)\n    }"
        }
        let short = (1 ... 50).map { index in
            "    func short\(index)(" + (1 ... 15).map { "placeholderCount\($0): Int" }.joined(separator: ", ") + ") -> Int { \(index) }"
        }
        try ("import Foundation\n/// A cut.\nstruct Cut {\n" + (long + short).joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent(cutPath), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// The command run in a context of `tokens`, as a replay hands its size over.
    private static func bash(_ command: String, context tokens: Int) -> [String: Any] {
        var payload = bash(command)
        payload[ContextSize.replayKey] = tokens
        return payload
    }

    /// `verdict` as the rule reads it: answered in place, or the line it is let through with.
    private static func ruled(_ verdict: String) -> String {
        verdict.hasPrefix("in-place") ? "in-place" : verdict
    }

    /// What the answerer serves `command` with, before any judgement of worth.
    private static func answered(_ command: String, in root: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws -> InPlaceAnswerer.Answered {
        let match = try #require(InPlaceShape.match(forShell: command, in: root.path), sourceLocation: sourceLocation)
        let backoff = try InPlaceAnswerTests.backoff()
        let outcome = await InPlaceAnswerTests.onItsOwnThread { InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff) }
        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer to \(command), got \(outcome)", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        return answered
    }

    /// The premise: the whole read is served the cut page, `head -n 390` the window's own cut page and `sed -n 4,390p` the members it overlaps, each window printing at least the share of the file.
    @Test
    func theCutFixtureIsServedAsTheFindingsSay() async throws {
        let root = try await Self.cutRepository()
        let file = root.appendingPathComponent(Self.cutPath).path

        let whole = try await Self.answered("cat \(Self.cutPath)", in: root)
        let head = try await Self.answered("head -n 390 \(Self.cutPath)", in: root)
        let members = try await Self.answered("sed -n 4,390p \(Self.cutPath)", in: root)

        #expect(whole.reason.contains("truncated: "), "\(whole.reason.suffix(300))")
        #expect(whole.calls.count == 1 && (whole.calls[0].bytes.source ?? 0) > 38000, "\(whole.calls)")
        #expect(head.reason.contains("truncated: "), "\(head.reason.suffix(300))")
        #expect(members.reason.contains("only the members"), "\(members.reason.prefix(300))")
        let total = try String(contentsOfFile: file, encoding: .utf8).split(separator: "\n").count
        #expect(total == 484 && Double(387) >= WholeReadWorth.windowShare * Double(total), "\(total) lines")
    }

    /// A window served its own cut page is weighed with the whole read's cut page against the whole file, so where `cat` is answered it is too.
    @Test(arguments: [100_000, 200_000])
    func aWindowServedItsCutPageAgreesWithTheWholeRead(context: Int) async throws {
        let root = try await Self.cutRepository()

        let whole = try await Self.decide({ Self.bash("cat \(Self.cutPath)", context: context) }, in: root)
        let head = try await Self.decide({ Self.bash("head -n 390 \(Self.cutPath)", context: context) }, in: root)
        let window = try await Self.decide({ Self.bash("sed -n 1,390p \(Self.cutPath)", context: context) }, in: root)

        #expect(Self.ruled(whole) == "in-place", "\(whole)")
        #expect(Self.ruled(head) == Self.ruled(whole), "\(head)")
        #expect(Self.ruled(window) == Self.ruled(whole), "\(window)")
    }

    /// A window served the members it overlaps is weighed with the cut page the whole read is served, not the uncut digest, so where `cat` is answered it is too.
    @Test(arguments: [200_000, 250_000])
    func aWindowServedMembersAgreesWithTheCutWholeRead(context: Int) async throws {
        let root = try await Self.cutRepository()

        let whole = try await Self.decide({ Self.bash("cat \(Self.cutPath)", context: context) }, in: root)
        let window = try await Self.decide({ Self.bash("sed -n 4,390p \(Self.cutPath)", context: context) }, in: root)

        #expect(Self.ruled(whole) == "in-place", "\(whole)")
        #expect(Self.ruled(window) == Self.ruled(whole), "\(window)")
    }

    /// Stepped across the context at which the whole read's margin crosses zero, from what `cat` is served, every covering window gets `cat`'s verdict at every step — on a file served its cut page and one whose whole digest fits the budget, its windows answered with members — and the steps reach both verdicts.
    @Test(arguments: [
        (true, ["head -n 390 Sources/App/Cut.swift", "sed -n 4,390p Sources/App/Cut.swift"]),
        (false, ["sed -n 3,200p Sources/App/Depot.swift", "sed -n '3,50p;52,200p' Sources/App/Depot.swift"]),
    ])
    func everyCoveringWindowAgreesWithTheWholeReadAcrossTheMargin(aboveBudget: Bool, windows: [String]) async throws {
        let root = try await aboveBudget ? Self.cutRepository() : Self.nestedRepository(inner: 12, padding: 710)
        let whole = "cat " + (aboveBudget ? Self.cutPath : "Sources/App/Depot.swift")
        let answered = try await Self.answered(whole, in: root)
        let served = try #require(answered.calls.first?.bytes)
        let margin = { (tokens: Int) in WholeReadWorth.margin(fileBytes: served.source ?? 0, digestBytes: served.served, contextTokens: tokens) }
        let crossing = margin(0) / (margin(0) - margin(1))
        #expect(answered.reason.contains("truncated: ") == aboveBudget && crossing > 0, "\(served), crossing \(crossing)")

        var seen = Set<String>()
        for share in [0.5, 0.8, 0.95, 0.99, 1.01, 1.05, 1.25, 1.6] {
            let context = Int(crossing * share)
            let expected = try await Self.ruled(Self.decide({ Self.bash(whole, context: context) }, in: root))
            seen.insert(expected)
            for window in windows {
                let verdict = try await Self.ruled(Self.decide({ Self.bash(window, context: context) }, in: root))
                #expect(verdict == expected, "\(window) at \(context) tokens: \(verdict), \(whole): \(expected)")
            }
        }

        #expect(seen == ["in-place", "allowed\t\tnotWorthTheTurn"], "\(seen)")
    }
}
