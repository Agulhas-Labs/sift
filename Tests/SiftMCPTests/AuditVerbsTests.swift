//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// `sift audit --verbs`: the answers sift gave, rowed by kind, priced, and followed to what the context did next.
@Suite(.temporaryDirectories)
struct AuditVerbsTests {
    /// One assistant request: a message id carrying usage, and the calls it makes.
    private static func request(_ message: String, _ calls: [Use] = [], at stamp: String? = nil) -> Data {
        let content: [[String: Any]] = calls.isEmpty
            ? [["type": "text", "text": "thinking"]]
            : calls.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": $0.input] }
        var object: [String: Any] = [
            "type": "assistant",
            "message": ["id": message, "usage": ["input_tokens": 1], "content": content],
        ]
        object["timestamp"] = stamp
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// A result the hook refused a call with: an error result.
    private static func refusal(_ id: String, _ text: String) -> Data {
        let object: [String: Any] = [
            "type": "user",
            "message": ["content": [["type": "tool_result", "tool_use_id": id, "is_error": true, "content": [["type": "text", "text": text]]]]],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func answer(_ id: String, _ text: String) -> Data {
        TranscriptFixture.indexAnswer(id: id, text: text)
    }

    private static func write(_ lines: [Data], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(lines.flatMap { $0 + [0x0A] }).write(to: url)
    }

    private static func scanned(_ lines: [Data], in directory: URL, since: Date? = nil, until: Date? = nil) throws -> AuditVerbs.Context {
        let transcript = directory.appendingPathComponent("projects/-repo/session.jsonl")
        try write(lines, to: transcript)
        let snapshot = TranscriptSnapshot.take(projectsDirectory: directory.appendingPathComponent("projects"), since: nil, transcript: transcript.path)
        return AuditVerbs.scan(transcript, snapshot: snapshot, since: since, until: until)
    }

    private static func rendered(_ lines: [Data], in directory: URL) throws -> String {
        try write(lines, to: directory.appendingPathComponent("projects/-repo/session.jsonl"))
        let snapshot = TranscriptSnapshot.take(projectsDirectory: directory.appendingPathComponent("projects"), since: nil, transcript: nil)
        return AuditVerbs.report(snapshot: snapshot, since: nil, until: nil, window: "--since 7d")
    }

    /// The table row of `kind`, as the figures after its name: calls, median, p90, price, share, then the five next shares.
    private static func row(_ kind: String, in report: String) -> [String]? {
        for line in report.split(separator: "\n") {
            let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if words.count > 10, words.dropLast(10).joined(separator: " ") == kind {
                return Array(words.suffix(10))
            }
        }
        return nil
    }

    @Test func anMCPCallAndACLICallOfOneKindShareARowAndAFlagMakesAnother() throws {
        let directory = try TemporaryDirectory.make("verbs-rows")
        let lines = [
            Self.request("m1", [Use("a", "mcp__sift__where", ["symbol": "Gizmo"])]), Self.answer("a", "one"),
            Self.request("m2", [Use("b", "mcp__sift__where", ["symbol": "Gizmo", "refs": true])]), Self.answer("b", "two"),
            Self.request("m3", [Use("c", "Bash", ["command": "sift where Gizmo --refs --root /x"])]), Self.answer("c", "three"),
            Self.request("m4", [Use("d", "Bash", ["command": "sift where Gizmo"])]), Self.answer("d", "four"),
            Self.request("m5"),
        ]
        let report = try Self.rendered(lines, in: directory)

        #expect(report.hasPrefix("audit --verbs: 4 answers in 1 session, --since 7d; price:"))
        #expect(Self.row("where", in: report)?[0] == "2")
        #expect(Self.row("where --refs", in: report)?[0] == "2")
        #expect(Self.row("where --refs --root /x", in: report) == nil)
        #expect(Self.row("where --root", in: report) == nil)
    }

    @Test func aDigestOfATypeAndOfAFileAreSeparateRows() throws {
        let directory = try TemporaryDirectory.make("verbs-digest")
        let lines = [
            Self.request("m1", [Use("a", "mcp__sift__digest", ["target": "Gizmo"])]), Self.answer("a", "x"),
            Self.request("m2", [Use("b", "mcp__sift__digest", ["target": "Sources/App/Gizmo.swift", "signaturesOnly": true])]), Self.answer("b", "x"),
            Self.request("m3", [Use("c", "Bash", ["command": "sift digest Gizmo.make Gizmo"])]), Self.answer("c", "x"),
            Self.request("m4"),
        ]
        let report = try Self.rendered(lines, in: directory)

        #expect(Self.row("digest (type)", in: report) != nil)
        #expect(Self.row("digest --signatures-only (file)", in: report) != nil)
        #expect(Self.row("digest (several)", in: report) != nil)
        #expect(AuditVerbs.digestShape(of: ["Gizmo.make"]) == "member")
        #expect(AuditVerbs.digestShape(of: ["Sources/App/Gizmo.swift:12"]) == "line")
        #expect(AuditVerbs.digestShape(of: ["Sources/App/Gizmo.swift:12-30"]) == "range")
        #expect(AuditVerbs.digestShape(of: ["."]) == "module")
        #expect(AuditVerbs.digestShape(of: ["Core/"]) == "module")
    }

    @Test func aHookAnswerIsRowedUnderTheFirstCallItsOpeningLineNames() throws {
        let directory = try TemporaryDirectory.make("verbs-hook")
        let opening = InPlaceAnswer.openingLine(calls: ["digest Sources/App/Gizmo.swift", "where Gizmo"])
        let lines = [
            Self.request("m1", [Use("a", "Read", ["file_path": "/r/Sources/App/Gizmo.swift"])]), Self.refusal("a", opening + "\n\nbody"),
            Self.request("m2", [Use("b", "Grep", ["pattern": "Gizmo"])]), Self.answer("b", "plain grep output"),
            Self.request("m3"),
        ]
        let report = try Self.rendered(lines, in: directory)

        #expect(report.hasPrefix("audit --verbs: 1 answer in 1 session"))
        #expect(Self.row("digest (file) (hook)", in: report) != nil)
    }

    @Test func aCallBesideTheAnswerInOneMessageIsNotWhatCameNext() throws {
        let directory = try TemporaryDirectory.make("verbs-parallel")
        let context = try Self.scanned([
            Self.request("m1", [Use("a", "mcp__sift__where", ["symbol": "Gizmo"])]),
            Self.answer("a", "Gizmo — Sources/Gizmo.swift:1-9"),
            Self.request("m1", [Use("b", "Grep", ["pattern": "Gizmo"])]), Self.answer("b", "grep hit"),
            Self.request("m2"),
        ], in: directory)

        #expect(context.answers.first?.next == AuditVerbs.Next.none)
    }

    @Test(arguments: [
        Later("Read", ["file_path": "/r/Sources/Gizmo.swift"], .read),
        Later("Read", ["file_path": "/r/Sources/Other.swift"], .other),
        Later("Bash", ["command": "sed -n '1,40p' Sources/Gizmo.swift"], .read),
        Later("Grep", ["pattern": "Gizmo"], .grep),
        Later("Bash", ["command": "rg Gizmo Sources"], .grep),
        Later("Grep", ["pattern": "Widget"], .other),
        Later("mcp__sift__digest", ["target": "Gizmo"], .sift),
        Later("Bash", ["command": "sift where Gizmo --refs"], .sift),
        Later("Bash", ["command": "ls"], .other),
        Later("Edit", ["file_path": "/r/Sources/Gizmo.swift"], .other),
    ])
    func theFirstLaterCallIsClassed(later: Later) throws {
        let directory = try TemporaryDirectory.make("verbs-next")
        let context = try Self.scanned([
            Self.request("m1", [Use("a", "mcp__sift__where", ["symbol": "Gizmo"])]), Self.answer("a", "Gizmo — Sources/Gizmo.swift:1-9"),
            Self.request("m2", [Use("b", later.name, later.input)]),
            Self.request("m3", [Use("c", "Grep", ["pattern": "Gizmo"])]),
        ], in: directory)

        #expect(context.answers.first?.next == later.expected)
    }

    @Test func noLaterCallIsNone() throws {
        let directory = try TemporaryDirectory.make("verbs-none")
        let context = try Self.scanned([
            Self.request("m1", [Use("a", "mcp__sift__where", ["symbol": "Gizmo"])]), Self.answer("a", "x"), Self.request("m2"),
        ], in: directory)

        #expect(context.answers.first?.next == AuditVerbs.Next.none)
    }

    @Test func theResultFirstReadByRequestJOfNCostsItsCharactersOverThreeAtTheBenchmarkRate() throws {
        let directory = try TemporaryDirectory.make("verbs-price")
        let text = String(repeating: "x", count: 300)
        let context = try Self.scanned([
            Self.request("m1", [Use("a", "mcp__sift__where", ["symbol": "Gizmo"])]), Self.answer("a", text),
            Self.request("m2"), Self.request("m3"), Self.request("m3"),
        ], in: directory)
        // Three requests, the answer first read by the second (j = 1): 100 tokens at 1.25 + 0.1 * (3 - 1 - 1).
        #expect(context.requests == 3)
        #expect(context.answers.first?.requestsBefore == 1)
        let price = try #require(context.answers.first?.price(requests: context.requests))

        #expect(abs(price - 135) < 1e-9)
    }

    @Test func aResultNoRequestReadCostsNothing() throws {
        let directory = try TemporaryDirectory.make("verbs-unread")
        let context = try Self.scanned([
            Self.request("m1", [Use("a", "mcp__sift__where", ["symbol": "Gizmo"])]), Self.answer("a", String(repeating: "x", count: 300)),
        ], in: directory)

        #expect(context.answers.first?.price(requests: context.requests) == 0)
    }

    @Test func aSubagentTranscriptIsItsOwnContextBesideItsSession() throws {
        let directory = try TemporaryDirectory.make("verbs-subagent")
        let session = directory.appendingPathComponent("projects/-repo/parent.jsonl")
        let one = [Self.request("m1", [Use("a", "mcp__sift__where", ["symbol": "Gizmo"])]), Self.answer("a", "x"), Self.request("m2")]
        try Self.write(one, to: session)
        try Self.write(one, to: directory.appendingPathComponent("projects/-repo/parent/subagents/agent-1.jsonl"))
        let snapshot = TranscriptSnapshot.take(projectsDirectory: directory.appendingPathComponent("projects"), since: nil, transcript: nil)
        let report = AuditVerbs.report(snapshot: snapshot, since: nil, until: nil, window: "--all")

        #expect(report.hasPrefix("audit --verbs: 2 answers in 1 session (+1 subagent), --all;"))
        #expect(Self.row("where", in: report)?[0] == "2")
    }

    @Test func linesThatAreNotAssistantOrUserAreNotRead() throws {
        let directory = try TemporaryDirectory.make("verbs-blob")
        var blob = try #require(JSONSerialization.jsonObject(with: Self.answer("a", "x")) as? [String: Any])
        blob["type"] = "system"
        let context = try Self.scanned([
            Self.request("m1", [Use("a", "mcp__sift__where", ["symbol": "Gizmo"])]), JSONSerialization.data(withJSONObject: blob),
        ], in: directory)

        #expect(context.answers.isEmpty)
    }

    @Test func theCostliestRowComesFirst() throws {
        let directory = try TemporaryDirectory.make("verbs-order")
        let report = try Self.rendered([
            Self.request("m1", [Use("a", "mcp__sift__where", ["symbol": "Gizmo"])]), Self.answer("a", "x"),
            Self.request("m2", [Use("b", "mcp__sift__strings", ["query": "Gizmo"])]), Self.answer("b", String(repeating: "x", count: 3000)),
            Self.request("m3"),
        ], in: directory)
        let rows = report.split(separator: "\n").dropFirst(2)

        #expect(rows.first?.hasPrefix("strings") == true)
        #expect(report.contains("kind"))
    }

    @Test(arguments: ["--replay", "--share", "--summary", "--scan-diff", "--unredact"])
    func verbsRefusesTheViewsItWouldReplaceNamingTheFlagToDrop(flag: String) throws {
        var arguments = ["--verbs", flag]
        if flag == "--scan-diff" {
            arguments += ["--against", "/bin/true"]
        }
        if flag == "--unredact" {
            _ = try AuditCommand.parse(arguments)
            return
        }
        do {
            _ = try AuditCommand.parse(arguments)
            Issue.record("\(flag) was accepted beside --verbs")
        } catch {
            let message = AuditCommand.message(for: error)

            #expect(message.contains("drop \(flag)"))
            #expect(!message.contains("\n"))
        }
    }

    @Test func verbsRefusesBy() throws {
        do {
            _ = try AuditCommand.parse(["--verbs", "--by", "day"])
            Issue.record("--by was accepted beside --verbs")
        } catch {
            #expect(AuditCommand.message(for: error).contains("drop --by"))
        }
    }

    @Test(arguments: [
        ("cd /r && sift digest Sources/App/Gizmo.swift 2>&1 | head -40", "digest (file)", ["Gizmo"]),
        ("sift --version 2>&1", "(no verb)", []),
        ("sift where Gizmo > /tmp/o.txt", "where", ["Gizmo"]),
        ("sift where Gizmo >/tmp/o.txt", "where", ["Gizmo"]),
        ("sift where Gizmo 2>/dev/null", "where", ["Gizmo"]),
        ("sift where Gizmo &> /tmp/o.txt", "where", ["Gizmo"]),
        ("sift strings \"<Settings>\"", "strings", ["Settings"]),
    ])
    func aRedirectionIsNotPartOfTheCall(command: String, kind: String, words: [String]) throws {
        let call = try #require(AuditVerbs.cliCall(command))

        #expect(call.kind == kind)
        #expect(call.words == words)
    }

    @Test func aPathOrACitedFileContributesOnlyItsStem() {
        #expect(AuditVerbs.words(in: ["Sources/App/Gizmo.swift"]) == ["Gizmo"])
        #expect(AuditVerbs.words(in: ["Sources/App/Gizmo.swift:12-40"]) == ["Gizmo"])
        #expect(AuditVerbs.words(in: ["Gizmo.make"]) == ["Gizmo", "make"])
        #expect(AuditVerbs.words(in: ["Core/"]).isEmpty)
    }

    @Test func aFileDigestIsNotFollowedUpBySwiftTestOrAGlobOfSwiftFiles() throws {
        for later in [
            Use("b", "Bash", ["command": "sift run -- swift test"]),
            Use("b", "Grep", ["pattern": "Widget", "glob": "*.swift"]),
        ] {
            let directory = try TemporaryDirectory.make("verbs-stem")
            let context = try Self.scanned([
                Self.request("m1", [Use("a", "Bash", ["command": "sift digest Sources/App/Gizmo.swift"])]), Self.answer("a", "x"),
                Self.request("m2", [later]),
                Self.request("m3"),
            ], in: directory)

            #expect(context.answers.first?.next == .other)
        }
    }

    @Test(arguments: [
        ("sift run -- swift   test --filter A", AuditVerbs.Next.sift),
        ("sift run --proved -- swift test --filter A", .sift),
        ("sift run -- swift test --filter B", .other),
        ("sift where swift", .other),
    ])
    func aRunIsFollowedUpOnlyByTheSameWrappedCommand(later: String, expected: AuditVerbs.Next) throws {
        let directory = try TemporaryDirectory.make("verbs-run")
        let context = try Self.scanned([
            Self.request("m1", [Use("a", "Bash", ["command": "sift run -- swift test --filter A"])]), Self.answer("a", "x"),
            Self.request("m2", [Use("b", "Bash", ["command": later])]),
            Self.request("m3"),
        ], in: directory)

        #expect(context.answers.first?.kind == "run")
        #expect(context.answers.first?.next == expected)
    }

    @Test func aRunIsNeverFollowedByAGrepOfItsWords() throws {
        let directory = try TemporaryDirectory.make("verbs-run-grep")
        let context = try Self.scanned([
            Self.request("m1", [Use("a", "Bash", ["command": "sift run -- swift test"])]), Self.answer("a", "x"),
            Self.request("m2", [Use("b", "Grep", ["pattern": "swift"])]),
            Self.request("m3"),
        ], in: directory)

        #expect(context.answers.first?.next == .other)
    }

    @Test(arguments: [
        ("sift test", "sift test", AuditVerbs.Next.sift),
        ("sift test --filter A", "sift test --filter  A", .sift),
        ("sift build --analyse", "sift build --analyse", .sift),
        ("sift test --filter A", "sift test --filter B", .other),
    ])
    func aTestOrBuildWithNoSeparatorIsFollowedUpByItsOwnArguments(first: String, later: String, expected: AuditVerbs.Next) throws {
        let directory = try TemporaryDirectory.make("verbs-noseparator")
        let context = try Self.scanned([
            Self.request("m1", [Use("a", "Bash", ["command": first])]), Self.answer("a", "x"),
            Self.request("m2", [Use("b", "Bash", ["command": later])]),
            Self.request("m3"),
        ], in: directory)

        #expect(context.answers.first?.next == expected)
    }

    @Test func aVerblessSiftSegmentDoesNotHideALaterSegmentsVerb() {
        #expect(AuditVerbs.cliCall("sift --version && sift where Gizmo")?.kind == "where")
        #expect(AuditVerbs.cliCall("sift --version")?.kind == "(no verb)")
    }

    @Test func aLookupIsNotFollowedUpByARunNamingItsTarget() throws {
        let directory = try TemporaryDirectory.make("verbs-lookup-run")
        let context = try Self.scanned([
            Self.request("m1", [Use("a", "Bash", ["command": "sift where Gizmo"])]), Self.answer("a", "x"),
            Self.request("m2", [Use("b", "Bash", ["command": "sift run -- swift test --filter Gizmo"])]),
            Self.request("m3"),
        ], in: directory)

        #expect(context.answers.first?.next == .other)
    }

    @Test func onlyAnErrorResultOfReadGrepOrBashIsAHookAnswer() throws {
        let opening = InPlaceAnswer.openingLine(calls: ["digest Sources/A.swift"])
        for (name, input, refused, rowed) in [
            ("Bash", ["command": "tail -1 hooklog.txt"], false, false),
            ("Edit", ["file_path": "/r/A.swift"], true, false),
            ("Bash", ["command": "tail -1 hooklog.txt"], true, true),
        ] {
            let directory = try TemporaryDirectory.make("verbs-hook-gate")
            let result = refused ? Self.refusal("a", opening) : Self.answer("a", opening)
            let context = try Self.scanned([Self.request("m1", [Use("a", name, input)]), result, Self.request("m2")], in: directory)

            #expect(context.answers.count == (rowed ? 1 : 0), "\(name) refused: \(refused)")
        }
    }

    @Test func onlyCallsInTheWindowAreReported() throws {
        let directory = try TemporaryDirectory.make("verbs-window")
        let stamps = ["2026-10-01T10:00:00.000Z", "2026-10-01T11:00:00.000Z", "2026-10-01T12:00:00.000Z", "2026-10-01T13:00:00.000Z"]
        var lines: [Data] = []
        for (index, stamp) in stamps.enumerated() {
            lines.append(Self.request("m\(index)", [Use("c\(index)", "mcp__sift__where", ["symbol": "Gizmo"])], at: stamp))
            lines.append(Self.answer("c\(index)", "x"))
        }
        lines.append(Self.request("m9", at: "2026-10-01T14:00:00.000Z"))
        let since = try #require(TranscriptScan.instant(stamps[1]))
        let until = try #require(TranscriptScan.instant(stamps[3]))
        let context = try Self.scanned(lines, in: directory, since: since, until: until)

        // From the second call on, before the fourth: the start is included, the end is not.
        #expect(context.answers.count == 2)
    }
}

extension AuditVerbsTests {
    /// A call a request makes: its tool id, the tool's name and its input.
    struct Use {
        let id: String
        let name: String
        let input: [String: Any]

        init(_ id: String, _ name: String, _ input: [String: Any] = [:]) {
            (self.id, self.name, self.input) = (id, name, input)
        }
    }

    struct Later: Sendable {
        let name: String
        let input: [String: String]
        let expected: AuditVerbs.Next

        init(_ name: String, _ input: [String: String], _ expected: AuditVerbs.Next) {
            (self.name, self.input, self.expected) = (name, input, expected)
        }
    }
}
