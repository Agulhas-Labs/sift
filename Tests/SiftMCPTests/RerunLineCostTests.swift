//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A whole read of a Swift file answered with its digest opens by saying what its identical re-run costs and naming the ranged read that costs less; every other answer keeps the suffix it had, and the reader of the line keys on the stem both share.
@Suite(.temporaryDirectories)
struct RerunLineCostTests {
    private static var old: String {
        " — re-run the identical command if you wanted its raw output."
    }

    private static func opening(of reason: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        try #require(reason.split(separator: "\n").first.map(String.init), sourceLocation: sourceLocation)
    }

    // MARK: - The suffix

    /// The figure is the file's bytes over the rule's own bytes-per-token constant: whole below a thousand tokens, one decimal and a `k` from there.
    @Test(arguments: [(0, "0"), (400, "100"), (3996, "999"), (4000, "1.0k"), (12400, "3.1k"), (20000, "5.0k"), (1_000_000, "250.0k")])
    func tokensAreWholeBelowAThousandAndOneDecimalAbove(bytes: Int, shown: String) {
        #expect(InPlaceAnswer.tokens(ofBytes: bytes) == shown)
        #expect(WholeReadWorth.bytesPerToken == 4)
    }

    /// The whole-read suffix states the file's lines and tokens and names the ranged read, and holds no parenthesis for the note's reader to mistake for an aside.
    @Test
    func theSuffixStatesTheCostAndNamesTheCheaperRouteWithoutParentheses() {
        let suffix = InPlaceAnswer.rerunSuffix(lines: 203, bytes: 12400)

        #expect(suffix == " — re-run the identical command for all 203 lines, about 3.1k tokens, or Read just a member's line range below with offset and limit.")
        #expect(!suffix.contains("(") && !suffix.contains(")"))
        #expect(InPlaceAnswer.openingLine(calls: ["digest A.swift"], rerun: (203, 12400)) == "sift answered this with `digest A.swift` instead of running it" + suffix)
        #expect(InPlaceAnswer.openingLine(calls: ["digest A.swift"]) == "sift answered this with `digest A.swift` instead of running it" + Self.old)
    }

    // MARK: - The reader keys on the stem

    /// Both forms, with and without an aside, with one call and with several, read back as the same calls and the same note.
    @Test
    func bothSuffixesParseToTheSameCallsAndNote() {
        let suffixes = [InPlaceAnswer.openingSuffix, InPlaceAnswer.rerunSuffix(lines: 203, bytes: 12400), InPlaceAnswer.rerunSuffix(lines: 9, bytes: 300)]
        for suffix in suffixes {
            let plain = "sift answered this with `digest Sources/App/Depot.swift` instead of running it" + suffix
            let noted = "sift answered this with `digest Sources/App/Depot.swift` (only the members of lines 1-5 are shown) instead of running it" + suffix
            let several = "sift answered this with `digest Screen.body`, `digest Row.body` instead of running it" + suffix

            #expect(InPlaceAnswer.calls(inOpeningLine: plain) == ["digest Sources/App/Depot.swift"], "\(suffix)")
            #expect(InPlaceAnswer.note(inOpeningLine: plain) == nil, "\(suffix)")
            #expect(InPlaceAnswer.calls(inOpeningLine: noted) == ["digest Sources/App/Depot.swift"], "\(suffix)")
            #expect(InPlaceAnswer.note(inOpeningLine: noted) == "only the members of lines 1-5 are shown", "\(suffix)")
            #expect(InPlaceAnswer.calls(inOpeningLine: several) == ["digest Screen.body", "digest Row.body"], "\(suffix)")
        }
    }

    /// A line written before the whole-read form existed, quoted as the transcript holds it, still reads as the answer it was.
    @Test
    func aLineWrittenWithTheOldSuffixStillReads() {
        let line = "sift answered this with `digest Sources/App/Depot.swift` instead of running it — re-run the identical command if you wanted its raw output."

        #expect(InPlaceAnswer.calls(inOpeningLine: line) == ["digest Sources/App/Depot.swift"])
        #expect(InPlaceAnswer.note(inOpeningLine: line) == nil)
    }

    /// A line without the stem is not an answer: another refusal, a different suffix, a stem with nothing before it.
    @Test(arguments: [
        "sift answered this with `digest A.swift` instead of running it — see the raw output.",
        "sift answered this with `digest A.swift` — re-run the identical command if you wanted its raw output.",
        "sift answered this with `digest A.swift` instead of running it, then re-run the identical command",
        " instead of running it — re-run the identical command for all 3 lines",
        "Run `digest A.swift` first.",
    ])
    func aLineWithoutTheStemIsNotAnAnswer(line: String) {
        #expect(InPlaceAnswer.calls(inOpeningLine: line) == nil)
        #expect(InPlaceAnswer.note(inOpeningLine: line) == nil)
    }

    // MARK: - Only a whole read states its re-run's cost

    /// A whole `cat` of a file the index holds opens with its line count and tokens, the figures being the file's own.
    @Test
    func aWholeReadsAnswerStatesTheFilesLinesAndTokens() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let file = root.appendingPathComponent("Sources/App/Depot.swift")
        let bytes = try #require(FileManager.default.contents(atPath: file.path)).count
        let answered = try #require(try await InPlaceAnswerTests.answered("cat Sources/App/Depot.swift", in: root))
        let opening = try Self.opening(of: answered.reason)

        #expect(opening == "sift answered this with `digest Sources/App/Depot.swift` instead of running it" + InPlaceAnswer.rerunSuffix(lines: 203, bytes: bytes))
        #expect(opening.hasSuffix("for all 203 lines, about \(InPlaceAnswer.tokens(ofBytes: bytes)) tokens, or Read just a member's line range below with offset and limit."))
        #expect(InPlaceAnswer.calls(inOpeningLine: opening) == ["digest Sources/App/Depot.swift"])
    }

    /// A ranged read's answer, a `Grep`'s and a `where` keep the old suffix byte for byte.
    @Test
    func everyOtherAnswerKeepsTheOldSuffix() async throws {
        let depot = try await InPlaceAnswerTests.indexedRepository(padding: InPlaceAnswerTests.pastTheFloor)
        let store = try await InPlaceAnswerTests.reviewedRepository()
        let commands = [
            (depot, "sed -n '1,200p' Sources/App/Depot.swift"),
            (depot, "head -150 Sources/App/Depot.swift"),
            (store, "grep -n 'var body' Sources/App/Screens.swift"),
        ]
        for (root, command) in commands {
            let answered = try #require(try await InPlaceAnswerTests.answered(command, in: root), "\(command) was not answered")
            let opening = try Self.opening(of: answered.reason)

            #expect(opening.hasSuffix(" instead of running it" + Self.old), "\(command): \(opening)")
            #expect(!opening.contains("for all"), "\(command): \(opening)")
        }
    }

    /// Only a digest weighing a whole file carries the figures: a `where` or a window's digest offers none, whatever the file's size.
    @Test
    func onlyAWholeFilesDigestOffersTheFigures() {
        let named = InPlaceAnswerer.ComputedCall(tool: "where", target: "Depot", served: 10, source: 4000, fileLines: 90)
        let windowed = InPlaceAnswerer.ComputedCall(tool: "digest", target: "Depot.swift", served: 10, source: 400, weighsWindow: true)
        let whole = InPlaceAnswerer.ComputedCall(tool: "digest", target: "Depot.swift", served: 10, source: 4000, fileLines: 90)
        let computed = { (calls: [InPlaceAnswerer.ComputedCall]) in InPlaceAnswerer.Computed(calls: calls, root: "/repo", answer: "", standsIn: "") }

        #expect(computed([named]).rerun == nil)
        #expect(computed([windowed]).rerun == nil)
        #expect(computed([whole, whole]).rerun == nil)
        #expect(computed([whole]).rerun?.lines == 90)
        #expect(computed([whole]).rerun?.bytes == 4000)
    }

    // MARK: - The gate and the line limit

    /// A repository whose `Sources/App/Long.swift` has exactly `lines` lines: a type of five-line members and comment lines after it.
    private static func repository(lines: Int) async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let members = (1 ... 399).map { index in
            "    func stock\(index)() -> Int {\n        let count = \(index)\n        let doubled = count * 2\n        return doubled + count\n    }"
        }
        let trailing = String(repeating: "// A depot.\n", count: lines - 1998)
        try ("/// A depot.\nstruct Long {\n" + members.joined(separator: "\n") + "\n}\n" + trailing)
            .write(to: root.appendingPathComponent("Sources/App/Long.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// A whole `Read` of a file of exactly the default `Read` limit is answered with the figures; of one line more, with the old suffix, since its identical re-run prints no more than 2000 lines.
    @Test(arguments: [(2000, true), (2001, false), (2604, false)])
    func aWholeReadOverTheDefaultLimitKeepsTheOldSuffix(lines: Int, figures: Bool) async throws {
        let root = try await Self.repository(lines: lines)
        let file = root.appendingPathComponent("Sources/App/Long.swift")
        let bytes = try #require(FileManager.default.contents(atPath: file.path)).count
        let read = try #require(InPlaceShape.match(forRead: file.path, in: root.path))
        let result = try await InPlaceAnswerTests.answer(read.call, from: read.directory, wholeCommand: read.isWholeCommand)
        guard case let .answered(answered) = result else {
            Issue.record("a Read of \(lines) lines was not answered: \(result)")
            return
        }
        let opening = try Self.opening(of: answered.reason)

        #expect(opening.hasSuffix(figures ? InPlaceAnswer.rerunSuffix(lines: lines, bytes: bytes) : " instead of running it" + Self.old), "\(opening)")
        #expect(LineWindow.readDefaultLimit == 2000)
    }

    /// The same file read by `cat` is answered by the same rule.
    @Test(arguments: [(2000, true), (2001, false)])
    func aCatOverTheDefaultLimitKeepsTheOldSuffix(lines: Int, figures: Bool) async throws {
        let root = try await Self.repository(lines: lines)
        let answered = try #require(try await InPlaceAnswerTests.answered("cat Sources/App/Long.swift", in: root))
        let opening = try Self.opening(of: answered.reason)

        #expect(opening.contains("for all \(lines) lines") == figures, "\(opening)")
        #expect(opening.hasSuffix(" instead of running it" + Self.old) != figures, "\(opening)")
    }

    /// A whole read that is not the whole command, one statement beside another that the shell runs, is served with the old suffix: its re-run runs the other statement too.
    @Test
    func aReadBesideAnotherStatementKeepsTheOldSuffix() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let command = "cd Sources/App && cat Depot.swift"
        let match = try #require(InPlaceShape.match(forShell: command, in: root.path))
        #expect(!match.isWholeCommand)
        let answered = try #require(try await InPlaceAnswerTests.answered(command, in: root), "\(command) was not answered")
        let opening = try Self.opening(of: answered.reason)

        #expect(opening.hasSuffix(" instead of running it" + Self.old), "\(opening)")
        #expect(!opening.contains("for all"), "\(opening)")
    }

    /// A line of two lookups of one file is answered with the one digest it is deduplicated to, and keeps the old suffix: the figures belong to a line that is one whole read, and its re-run prints the file twice.
    @Test
    func twoLookupsOfOneFileAnsweredByOneDigestKeepTheOldSuffix() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let digest = InPlaceCall.fileDigest(path: "Sources/App/Depot.swift")
        let match = InPlaceShape.Match(calls: [digest, digest], directory: root.path, isWholeCommand: true)
        let backoff = try InPlaceAnswerTests.backoff()
        let result = await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }
        guard case let .answered(answered) = result else {
            Issue.record("two lookups of one file were not answered: \(result)")
            return
        }
        let opening = try Self.opening(of: answered.reason)

        #expect(answered.calls.count == 1)
        #expect(opening.hasSuffix(" instead of running it" + Self.old), "\(opening)")
        #expect(!opening.contains("for all"), "\(opening)")
    }

    // MARK: - The cheaper route is let through

    /// End to end through the hook: the whole read is answered with the figures, and a ranged `Read` of a member's lines from that answer, in the same context, is not answered again.
    @Test
    func theRangedReadTheAnswerNamesIsLetThrough() async throws {
        let root = try await WorthAnsweringFixture.repository()
        let directory = try TemporaryDirectory.make("rerun-route").appendingPathComponent("route")
        defer { try? FileManager.default.removeItem(at: directory) }
        let usageLog = directory.appendingPathComponent("usage.jsonl")
        let suppressionLog = directory.appendingPathComponent("suppressions.jsonl")
        let ledger = AdviceLedger(directory: directory.appendingPathComponent("advice"))
        let file = root.appendingPathComponent("Sources/App/Depot.swift").path
        let backoff = try InPlaceAnswerTests.backoff()

        let hook = { @Sendable (input: [String: Any]) -> String? in
            let payload: [String: Any] = ["tool_name": "Read", "tool_input": input, "session_id": "s1"]
            guard let lookup = PreToolUseCommand.lookup(
                command: nil,
                payload: payload,
                in: root.path,
                noting: SuppressionLog(fileURL: suppressionLog),
                digested: DigestedFiles(usageLog: usageLog),
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
                ledger: ledger,
                usage: UsageLog(fileURL: usageLog),
                suppressions: SuppressionLog(fileURL: suppressionLog),
                answerer: { match, gone, _ in InPlaceAnswerer.answer(match.call, from: match.directory, serverGone: gone, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff) }
            )
        }
        let whole = await InPlaceAnswerTests.onItsOwnThread { hook(["file_path": file]) }
        let data = try #require(whole.map { Data($0.utf8) })
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reason = try #require((object["hookSpecificOutput"] as? [String: Any])?["permissionDecisionReason"] as? String)
        let opening = try Self.opening(of: reason)
        let member = try #require(reason.firstMatch(of: /func stock10\(\) -> Int  :(\d+)-(\d+)/))
        let first = try #require(Int(member.1))
        let last = try #require(Int(member.2))

        let bytes = try #require(FileManager.default.contents(atPath: file)).count
        #expect(opening.hasSuffix(InPlaceAnswer.rerunSuffix(lines: 203, bytes: bytes)), "\(opening)")

        let ranged = await InPlaceAnswerTests.onItsOwnThread { hook(["file_path": file, "offset": first, "limit": last - first + 1]) }

        #expect(ranged == nil, "\(ranged ?? "")")
    }
}
