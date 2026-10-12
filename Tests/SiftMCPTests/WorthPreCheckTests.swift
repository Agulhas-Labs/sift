//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A reading no answer could be worth the turn for is withheld as `notWorthTheTurn` before its answer is built, and the bound that decides it never withholds a reading the late weighing would have answered.
@Suite(.temporaryDirectories)
struct WorthPreCheckTests {
    /// The context every call here is weighed in, handed over as a replay hands it.
    private static let context = 45000

    /// A payload for a `Read` of `file`, whole or through a window, or for a shell `command`, in a context of `tokens`.
    private static func payload(read file: String? = nil, offset: Int? = nil, limit: Int? = nil, command: String? = nil, tokens: Int = context) -> [String: Any] {
        var input: [String: Any] = [:]
        if let file {
            input["file_path"] = file
        }
        if let offset, let limit {
            input["offset"] = offset
            input["limit"] = limit
        }
        if let command {
            input["command"] = command
        }
        return ["tool_name": file == nil ? "Bash" : "Read", "tool_input": input, "tool_use_id": "toolu_p1", ContextSize.replayKey: tokens]
    }

    /// Swift source of `lines` lines, each 40 bytes with its newline, so a file's size is set to the line.
    private static func source(lines: Int, broken: Bool = false) -> String {
        let body = (0 ..< max(lines - 2, 0)).map { String(format: "    let value%05d = 1 // %@", $0, String(repeating: "x", count: 13)) }
        return (["struct Depot {"] + body + [broken ? "    func (" : "}"]).joined(separator: "\n") + "\n"
    }

    /// A repository with no index, holding `Sources/App/Depot.swift` of `lines` lines.
    private static func repository(lines: Int, broken: Bool = false) throws -> (root: URL, file: String) {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let file = root.appendingPathComponent("Sources/App/Depot.swift")
        try Self.source(lines: lines, broken: broken).write(to: file, atomically: true, encoding: .utf8)
        return (root, file.path)
    }

    /// The hook's verdict on `payload` run from `root` with the real answerer, and whether the repository has an index afterwards, which only an answer built for the call could have made.
    private static func hook(_ payload: [String: Any], in root: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws -> (rule: String?, indexed: Bool) {
        let scratch = try TemporaryDirectory.make("worth-pre-check")
        let backoff = try InPlaceAnswerTests.backoff()
        let suppressions = SuppressionLog(fileURL: scratch.appendingPathComponent("suppressions.jsonl"))
        let command = (payload["tool_input"] as? [String: Any])?["command"] as? String
        let lookup = try #require(PreToolUseCommand.lookup(command: command, payload: payload, in: root.path, noting: suppressions, couldAnswer: { _, _ in true }), sourceLocation: sourceLocation)
        let unsent = UnsentLookup(lookup: lookup, payload: payload)
        let rule = await InPlaceAnswerTests.onItsOwnThread {
            PreToolUseCommand.outcome(
                to: unsent.lookup,
                session: "s1",
                context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil),
                payload: unsent.payload,
                command: command,
                cwd: root.path,
                ledger: AdviceLedger(directory: scratch.appendingPathComponent("advice")),
                usage: UsageLog(fileURL: scratch.appendingPathComponent("usage.jsonl")),
                suppressions: suppressions,
                answerer: { match, gone, budget in InPlaceAnswerer.answer(match, serverGone: gone, timeBudget: max(budget, InPlaceAnswerTests.roomy), backoff: backoff) }
            ).verdict.rule
        }
        return (rule, ReadOnlyIndex.hasUsableIndex(atRoot: root.path))
    }

    /// A small whole `Read` is let through as `notWorthTheTurn` without any answer being built: the repository it reads in is left with no index.
    @Test
    func aSmallWholeReadIsWithheldWithoutBuildingItsAnswer() async throws {
        let (root, file) = try Self.repository(lines: 30)

        let judged = try await Self.hook(Self.payload(read: file), in: root)

        #expect(judged.rule == "notWorthTheTurn")
        #expect(!judged.indexed, "the answer was built")
    }

    /// A small whole `Read` of a file holding a parse error is let through as `notWorthTheTurn`, which the size bound settles before the parse is looked at.
    @Test
    func aSmallReadWithAParseErrorIsWithheldOnWorth() async throws {
        let (root, file) = try Self.repository(lines: 30, broken: true)

        let judged = try await Self.hook(Self.payload(read: file), in: root)

        #expect(judged.rule == "notWorthTheTurn")
        #expect(!judged.indexed, "the answer was built")
    }

    /// A file just above the bound is not settled by it: its answer is built and weighed after.
    @Test
    func aFileJustAboveTheBoundTakesTheLatePath() async throws {
        let bound = try #require(Self.boundBytes(tokens: Self.context))
        let (root, file) = try Self.repository(lines: bound / 40 + 4)
        let payload = Self.payload(read: file)
        let match = try #require(try Self.match(payload, in: root.path))

        #expect(!WorthBeforeAnswer.settles(match, payload: payload))
        #expect(try await Self.hook(payload, in: root).indexed, "the answer was not built")
    }

    /// A `sed -n` window is never weighed before its answer, however small: the window rules judge it once it is built.
    @Test
    func aShellWindowIsNeverPreChecked() async throws {
        let (root, file) = try Self.repository(lines: 30)
        let payload = Self.payload(command: "sed -n 1,10p \(file)")
        let match = try #require(try Self.match(payload, in: root.path))

        #expect(!WorthBeforeAnswer.settles(match, payload: payload))
        #expect(try await Self.hook(payload, in: root).indexed, "the answer was not built")
    }

    /// The match the hook reads `payload` as, from `directory`.
    private static func match(_ payload: [String: Any], in directory: String) throws -> InPlaceShape.Match? {
        let suppressions = try SuppressionLog(fileURL: TemporaryDirectory.make("worth-pre-check-ignored").appendingPathComponent("ignored.jsonl"))
        let command = (payload["tool_input"] as? [String: Any])?["command"] as? String
        return PreToolUseCommand.lookup(command: command, payload: payload, in: directory, noting: suppressions, couldAnswer: { _, _ in true })?.inPlace
    }

    /// The largest file, in bytes, a whole read of which an answer of no bytes is not worth the turn for, in a context of `tokens`.
    private static func boundBytes(tokens: Int) -> Int? {
        (1 ... 200_000).last { WholeReadWorth.margin(fileBytes: $0, digestBytes: 0, contextTokens: tokens) <= 0 }
    }
}

extension WorthPreCheckTests {
    /// A lookup and its payload handed to the thread the hook runs on.
    struct UnsentLookup: @unchecked Sendable {
        let lookup: PreToolUseCommand.Lookup
        let payload: [String: Any]
    }

    /// The shapes the grid weighs a file through: a whole `Read`, a `Read` window over most of the file, and a narrower one.
    enum Shape: CaseIterable {
        case whole, most, narrow

        /// The `Read` of `file`, `lines` long, in this shape.
        func payload(_ file: String, lines: Int, tokens: Int) -> [String: Any] {
            switch self {
            case .whole:
                WorthPreCheckTests.payload(read: file, tokens: tokens)
            case .most:
                WorthPreCheckTests.payload(read: file, offset: 1, limit: lines * 4 / 5, tokens: tokens)
            case .narrow:
                WorthPreCheckTests.payload(read: file, offset: 1, limit: max(lines / 10, 1), tokens: tokens)
            }
        }
    }

    /// Wherever the bound withholds before the build, the late weighing withholds too for every answer of any size the build could produce: a grid over file sizes straddling each shape's bound, in three contexts.
    @Test(arguments: [20000, 45000, 200_000])
    func theBoundNeverWithholdsWhatTheLateWeighingWouldAnswer(tokens: Int) throws {
        let directory = try TemporaryDirectory.make("worth-pre-check-grid")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        let wholeBound = try #require(Self.boundBytes(tokens: tokens))
        // The narrow window's bound in bytes of its file: the window prints a tenth of the file.
        let windowBound = try #require((1 ... 200_000).last { WholeReadWorth.readWindowMargin(windowBytes: $0, answerBytes: 0, contextTokens: tokens) <= 0 }) * 10
        var settled = 0
        for shape in Shape.allCases {
            let bound = shape == .narrow ? windowBound : wholeBound
            for share in [0.3, 0.6, 0.9, 0.98, 1.02, 1.1, 1.5, 1.9, 2.5] {
                let lines = max(Int(Double(bound) * share) / 40, 10)
                let file = directory.appendingPathComponent("Sources/Depot\(lines).swift")
                try Self.source(lines: lines).write(to: file, atomically: true, encoding: .utf8)
                let payload = shape.payload(file.path, lines: lines, tokens: tokens)
                let match = try #require(try Self.match(payload, in: directory.path))
                guard WorthBeforeAnswer.settles(match, payload: payload) else { continue }
                settled += 1
                for served in [0, 1, 100, 1000, 10000] {
                    let late = try WholeReadWorth.weighing(Self.answered(match, served: served), of: match, payload: payload)
                    #expect(late == .withheld(.notWorthTheTurn), "\(shape) of \(lines) lines in \(tokens): the late weighing answers an answer of \(served) bytes")
                }
            }
        }

        #expect(settled >= 6, "the grid never reaches the bound")
    }

    /// The answer the build would hand the late weighing for `match`, `served` bytes long: the whole digest, carrying the whole read's bytes where its windows print most of the file, and weighed against the lines its windows print where they do not.
    private static func answered(_ match: InPlaceShape.Match, served: Int, sourceLocation: SourceLocation = #_sourceLocation) throws -> InPlaceAnswerer.Outcome {
        guard case let .fileDigest(path, windows) = match.call else { throw CancellationError() }
        let read = try #require(OperandFile.onDisk(path, in: match.directory), sourceLocation: sourceLocation)
        let window = OperandFile.windowBytes(of: windows, in: read.lines, byteLengths: read.byteLengths)
        let whole = AnswerBytes(served: served, source: read.bytes)
        let call = InPlaceAnswerer.Call(tool: "digest", target: path, bytes: AnswerBytes(served: served, source: window ?? read.bytes))
        let printsMost = !windows.isEmpty && WholeReadWorth.printsMost(windows, ofFileAt: path, in: match.directory)
        return .answered(InPlaceAnswerer.Answered(reason: "answer", calls: [call], root: "/", milliseconds: 1, wholeRead: printsMost ? whole : nil))
    }
}
