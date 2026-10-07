//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A whole digest whose refusal runs past the size budget is answered with its first page cut to the most member lines that fit, ending in the cursor that pages it.
@Suite(.temporaryDirectories)
struct PagedAnswerTests {
    private static var path: String {
        "Sources/App/Crate.swift"
    }

    /// A repository whose `Crate` has `count` members (`dense`: each on one line, so the source is hardly larger than its digest), each a signature with a doc summary long enough that sixty of them are a digest over the size budget, over a body padded by `padding` bytes.
    private static func repository(members count: Int = 70, padding: Int = 160, dense: Bool = false, imports: Bool = false) async throws -> URL {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let summary = "Takes crate number %d out of the stack and weighs it against the others the depot is holding for the harbour."
        let pad = padding > 0 ? " //" + String(repeating: "x", count: padding - 3) : ""
        let members = (1 ... count).map { index in
            dense
                ? "    /// \(summary.replacingOccurrences(of: "%d", with: "\(index)"))\n    func take\(index)(first: Int, second: String, third: [Int], fourth: Double) -> Int { \(index) }"
                : "    /// \(summary.replacingOccurrences(of: "%d", with: "\(index)"))\n    func take\(index)(first: Int, second: String, third: [Int], fourth: Double) -> Int {\n        let count = \(index)\(pad)\n        return count * 2\n    }"
        }
        try ((imports ? "import Foundation\n" : "") + "/// A crate.\nstruct Crate {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    private static func answered(_ command: String, in root: URL, serverGone: Bool = false, sizeBudget: Int = InPlaceAnswer.sizeBudget, sourceLocation: SourceLocation = #_sourceLocation) async throws -> InPlaceAnswerer.Outcome {
        let match = try #require(InPlaceShape.match(forShell: command, in: root.path), sourceLocation: sourceLocation)
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, serverGone: serverGone, timeBudget: InPlaceAnswerTests.roomy, sizeBudget: sizeBudget, backoff: backoff)
        }
    }

    /// The cursor a page ends with: the member lines it leaves, and the offset it says to pass.
    private static func cursor(in reason: String) -> Cursor? {
        guard let line = reason.split(separator: "\n").last(where: { $0.hasPrefix("truncated: ") }),
              let match = line.firstMatch(of: /truncated: (\d+) more member lines — pass (offset: |--offset )(\d+)/),
              let remaining = Int(match.1), let offset = Int(match.3)
        else { return nil }
        return Cursor(remaining: remaining, offset: offset, spelled: String(match.2))
    }

    /// The number each `take` member line of `text` names, in order.
    private static func taken(in text: String) -> [Int] {
        text.split(separator: "\n").compactMap { $0.firstMatch(of: /func take(\d+)\(/).flatMap { Int($0.1) } }
    }

    /// What `digestAnswer` computes for a read of the file through `windows`, cutting as the hook does, and how many pages it rendered to size the cut.
    private static func computed(_ windows: [LineWindow], in root: URL) async throws -> (computation: InPlaceAnswerer.Computation, renders: Int) {
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        let conditions = try InPlaceAnswerer.Conditions(directory: root.path, serverGone: false, wholeCommand: true, lookups: 1, sizeBudget: InPlaceAnswer.sizeBudget, backoff: InPlaceAnswerTests.backoff(), oversized: nil)
        var renders = 0
        let computation = try InPlaceAnswerer.digestAnswer(path, windows: windows, in: root.path, engine: engine, freshness: freshness, spelling: .toolCall, cutting: conditions) { renders += 1 }
        return (computation, renders)
    }

    // MARK: - The cut page

    /// A whole read whose sixty-line digest is over the budget is answered with a page of fewer member lines, inside the budget, ending in the cursor spelled for the face that asked.
    @Test(arguments: [false, true])
    func aWholeReadOverTheBudgetIsAnsweredWithItsFirstPageCutToFit(serverGone: Bool) async throws {
        let root = try await Self.repository()
        let outcome = try await Self.answered("cat \(Self.path)", in: root, serverGone: serverGone)

        guard case let .answered(answered) = outcome else {
            Issue.record("expected the first page, got \(outcome)")
            return
        }
        let cursor = try #require(Self.cursor(in: answered.reason), "\(answered.reason.suffix(300))")

        #expect(answered.reason.utf8.count <= InPlaceAnswer.sizeBudget)
        #expect(cursor.spelled == (serverGone ? "--offset " : "offset: "))
        #expect(cursor.offset < DigestOptions().pageSize)
        // The type's own line is a counted member line too.
        #expect(Self.taken(in: answered.reason) == Array(1 ..< cursor.offset))
        #expect(cursor.remaining == 71 - cursor.offset)
        #expect(answered.calls.map(\.target) == [Self.path])
        #expect(answered.calls[0].bytes.served == answered.reason.utf8.count)
    }

    /// The page is the largest that fits: the same page one member line longer is framed over the budget.
    @Test
    func theCutPageIsTheLargestThatFits() async throws {
        let root = try await Self.repository()
        guard case let .answered(answered) = try await Self.answered("cat \(Self.path)", in: root) else {
            Issue.record("expected the first page")
            return
        }
        let cursor = try #require(Self.cursor(in: answered.reason))
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        let longer = try #require(try FileDigestParts.wholeFileDigest(Self.path, in: root.path, engine: engine, spelling: .toolCall, pageSize: cursor.offset + 1))
        let header = try engine.framing(freshness).headerLine
        let computed = InPlaceAnswerer.Computed(calls: [longer.call], root: root.path, answer: header + "\n" + longer.text, standsIn: "this digest did not weigh itself against the file's source")
        let backoff = try InPlaceAnswerTests.backoff()
        let conditions = InPlaceAnswerer.Conditions(directory: root.path, serverGone: false, wholeCommand: true, lookups: 1, sizeBudget: InPlaceAnswer.sizeBudget, backoff: backoff, oversized: nil)

        #expect(InPlaceAnswerer.framed(computed, note: nil, under: conditions).1.served > InPlaceAnswer.sizeBudget)
    }

    /// `sift digest F --offset K` continues exactly where the cut page stopped: its first member line is the one after the page's last.
    @Test
    func theCursorPagesOnFromTheLastMemberShown() async throws {
        let root = try await Self.repository()
        guard case let .answered(answered) = try await Self.answered("cat \(Self.path)", in: root) else {
            Issue.record("expected the first page")
            return
        }
        let cursor = try #require(Self.cursor(in: answered.reason))
        let shown = Self.taken(in: answered.reason)
        let engine = try SiftEngine(directory: root)
        try await engine.ensureFresh()
        let next = try engine.measuredDigest(target: Self.path, options: DigestOptions(offset: cursor.offset)).text
        let continued = Self.taken(in: next)

        #expect(shown == Array(1 ..< cursor.offset))
        #expect(continued.first == cursor.offset)
        #expect(continued == Array(cursor.offset ... min(cursor.offset + DigestOptions().pageSize - 1, 70)))
    }

    /// A digest whose sixty lines fit the budget is answered whole, as ever: nothing is cut.
    @Test
    func aDigestInsideTheBudgetIsNotCut() async throws {
        let root = try await Self.repository(members: 30)
        guard case let .answered(answered) = try await Self.answered("cat \(Self.path)", in: root) else {
            Issue.record("expected the digest")
            return
        }

        #expect(Self.cursor(in: answered.reason) == nil)
        #expect(Self.taken(in: answered.reason).count == 30)
    }

    // MARK: - The route

    /// After the page answer a ranged read of the file passes in the same context, and so does the identical re-run.
    @Test
    func theRangedReadAndTheIdenticalRerunPassAfterThePage() async throws {
        let root = try await Self.repository()
        let scratch = try TemporaryDirectory.make("paged-answer")
        let backoff = try InPlaceAnswerTests.backoff()
        let file = root.appendingPathComponent(Self.path).path
        let path = root.path

        let verdicts = await InPlaceAnswerTests.onItsOwnThread { () -> [String] in
            let ledger = AdviceLedger(directory: scratch.appendingPathComponent("advice"))
            let suppressions = SuppressionLog(fileURL: scratch.appendingPathComponent("suppressions.jsonl"))
            return ["cat \(file)", "sed -n 10,40p \(file)", "cat \(file)"].enumerated().map { index, command in
                let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": command], "tool_use_id": "toolu_\(index)"]
                guard let lookup = PreToolUseCommand.lookup(command: command, payload: payload, in: path, noting: suppressions, couldAnswer: { _, _ in true }) else { return "no lookup" }
                let outcome = PreToolUseCommand.outcome(
                    to: lookup,
                    session: "s1",
                    context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: nil),
                    payload: payload,
                    command: command,
                    cwd: path,
                    ledger: ledger,
                    usage: UsageLog(fileURL: scratch.appendingPathComponent("usage.jsonl")),
                    suppressions: suppressions,
                    answerer: { match, gone, _ in InPlaceAnswerer.answer(match, serverGone: gone, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff) }
                )
                return outcome.json == nil ? "\(outcome.verdict.token)/\(outcome.verdict.rule ?? "")" : outcome.verdict.token
            }
        }

        #expect(verdicts.first == "in-place", "\(verdicts)")
        #expect(verdicts.dropFirst().allSatisfy { $0.hasPrefix("allowed") }, "\(verdicts)")
    }

    /// The rule weighs the page's served bytes, not the whole digest's.
    @Test
    func theRuleWeighsThePageAsD() async throws {
        let root = try await Self.repository()
        let match = try #require(InPlaceShape.match(forShell: "cat \(Self.path)", in: root.path))
        let backoff = try InPlaceAnswerTests.backoff()
        let outcome = await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }
        guard case let .answered(answered) = outcome else {
            Issue.record("expected the first page, got \(outcome)")
            return
        }
        let bytes = answered.calls[0].bytes
        let source = try #require(bytes.source)

        #expect(bytes.served == answered.reason.utf8.count)
        #expect(bytes.served <= InPlaceAnswer.sizeBudget)
        let judged = WholeReadWorth.weighing(outcome, of: match, payload: ["tool_name": "Bash"])
        #expect(judged == (WholeReadWorth.isWorthTheTurn(fileBytes: source, digestBytes: bytes.served, contextTokens: nil) ? outcome : .withheld(.notWorthTheTurn)))
    }

    /// In a context where the page's bytes leave a positive margin and the whole digest's would not, the read is answered: the rule weighs the page.
    @Test
    func theRuleAnswersWhereOnlyThePageIsWorthTheTurn() async throws {
        let root = try await Self.repository(padding: 400)
        let match = try #require(InPlaceShape.match(forShell: "cat \(Self.path)", in: root.path))
        let backoff = try InPlaceAnswerTests.backoff()
        let page = await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }
        let uncut = await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, sizeBudget: .max, backoff: backoff)
        }
        guard case let .answered(paged) = page, case let .answered(whole) = uncut else {
            Issue.record("expected both answers, got \(page) and \(uncut)")
            return
        }
        let source = try #require(paged.calls[0].bytes.source)
        let (pageBytes, wholeBytes) = (paged.calls[0].bytes.served, whole.calls[0].bytes.served)
        // The margin falls by the same amount for each token of context, so each digest has the context it stops paying at.
        let slope = WholeReadWorth.margin(fileBytes: source, digestBytes: pageBytes, contextTokens: 1) - WholeReadWorth.margin(fileBytes: source, digestBytes: pageBytes, contextTokens: 0)
        let stops = { (digest: Int) in -WholeReadWorth.margin(fileBytes: source, digestBytes: digest, contextTokens: 0) / slope }
        #expect(wholeBytes > InPlaceAnswer.sizeBudget && pageBytes < wholeBytes)
        #expect(stops(pageBytes) > stops(wholeBytes) + 2, "page \(stops(pageBytes)), whole \(stops(wholeBytes))")
        let context = Int((stops(pageBytes) + stops(wholeBytes)) / 2)

        #expect(WholeReadWorth.isWorthTheTurn(fileBytes: source, digestBytes: pageBytes, contextTokens: context))
        #expect(!WholeReadWorth.isWorthTheTurn(fileBytes: source, digestBytes: wholeBytes, contextTokens: context))
        let payload: [String: Any] = ["tool_name": "Bash", ContextSize.replayKey: context]
        #expect(WholeReadWorth.weighing(page, of: match, payload: payload) == page)
        #expect(WholeReadWorth.weighing(uncut, of: match, payload: payload) == .withheld(.notWorthTheTurn))
    }

    // MARK: - The cut costs nothing where it cannot change the outcome

    /// A whole read is sized in a few renders, and the page is the one served.
    @Test
    func aWholeReadIsSizedInFewRenders() async throws {
        let root = try await Self.repository()
        let (computation, renders) = try await Self.computed([], in: root)
        guard case let .answer(_, _, cut) = computation, let cut else {
            Issue.record("expected a cut page, got \(computation)")
            return
        }
        guard case let .answered(answered) = try await Self.answered("cat \(Self.path)", in: root) else {
            Issue.record("expected the first page")
            return
        }

        #expect(renders >= 1 && renders <= 4, "\(renders) renders")
        #expect(Self.taken(in: cut.answer) == Self.taken(in: answered.reason))
    }

    /// A window that ends `linesNotShown` renders no page: the cut cannot change that outcome.
    @Test
    func aWindowEndingLinesNotShownRendersNoPage() async throws {
        let root = try await Self.repository()
        let (computation, renders) = try await Self.computed([LineWindow(offset: 1, limit: 12)], in: root)
        let outcome = try await Self.answered("sed -n 1,12p \(Self.path)", in: root)

        #expect(outcome == .withheld(.linesNotShown), "\(outcome)")
        if case let .answer(_, _, cut) = computation {
            #expect(cut == nil)
        }
        #expect(renders == 0, "\(renders) renders")
    }

    /// A window the members answer wins renders no page either.
    @Test
    func aWindowTheMembersAnswerWinsRendersNoPage() async throws {
        let root = try await Self.repository(padding: 600)
        let last = 2 + 20 * 5
        let (_, renders) = try await Self.computed([LineWindow(offset: 1, limit: last)], in: root)
        let outcome = try await Self.answered("sed -n 1,\(last)p \(Self.path)", in: root)

        guard case let .answered(answered) = outcome else {
            Issue.record("expected the members answer, got \(outcome)")
            return
        }

        #expect(answered.reason.contains("only the members"), "\(answered.reason.prefix(300))")
        #expect(renders == 0, "\(renders) renders")
    }

    // MARK: - Where the page does not stand in

    /// A page saving under the floor on the file it stands in for is not served: the read runs as `overSize`.
    @Test
    func aPageSavingUnderTheFloorRunsAsOverSize() async throws {
        // Fifty-four members: a digest over the budget that is smaller than the source, which a cut saves 3.9 KB of, under the floor.
        let root = try await Self.repository(members: 54, padding: 0)
        let outcome = try await Self.answered("cat \(Self.path)", in: root)

        #expect(outcome == .withheld(.overSize), "\(outcome)")
    }

    /// A window whose members lie past the cut page runs as `overSize`, since the page reaches none of them.
    @Test
    func aWindowPastTheCutPageRunsAsOverSize() async throws {
        let root = try await Self.repository()
        // The sixty-line page reaches member 58; the cut page, of fewer lines, does not, and the members answer over
        // fifty-eight members is itself over the budget.
        let last = 2 + 58 * 5
        let outcome = try await Self.answered("sed -n 1,\(last)p \(Self.path)", in: root)

        #expect(outcome == .withheld(.overSize), "\(outcome)")
    }

    /// A window over a file's imports, which the members never account for, is answered with the cut page where the page reaches its last member, and runs as `overSize` one line further.
    @Test
    func aWindowOverImportsIsAnsweredWithThePageWhereItReaches() async throws {
        let root = try await Self.repository(imports: true)
        guard case let .answered(whole) = try await Self.answered("cat \(Self.path)", in: root) else {
            Issue.record("expected the first page")
            return
        }
        let cursor = try #require(Self.cursor(in: whole.reason))
        // The import, the doc line and the type's line, then five lines to each member listed.
        let end = 3 + 5 * (cursor.offset - 1)
        let inside = try await Self.answered("sed -n 1,\(end)p \(Self.path)", in: root)
        let past = try await Self.answered("sed -n 1,\(end + 1)p \(Self.path)", in: root)

        guard case let .answered(answered) = inside else {
            Issue.record("expected the cut page, got \(inside)")
            return
        }

        #expect(Self.cursor(in: answered.reason)?.offset == cursor.offset)
        #expect(past == .withheld(.overSize), "\(past)")
    }

    /// One lookup on a line with other statements is cut like any single-file answer.
    @Test
    func aLoneLookupOnACompoundLineIsCut() async throws {
        let root = try await Self.repository()
        guard case let .answered(answered) = try await Self.answered("cat \(Self.path) && echo done", in: root) else {
            Issue.record("expected the cut page")
            return
        }

        #expect(Self.cursor(in: answered.reason) != nil, "\(answered.reason.suffix(300))")
        #expect(answered.reason.utf8.count <= InPlaceAnswer.sizeBudget)
    }

    /// A line of two files is never cut: over the budget it runs as `overSize`.
    @Test
    func aLineOfTwoFilesIsNeverCut() async throws {
        let root = try await Self.repository()
        let outcome = try await Self.answered("cat \(Self.path) && cat Sources/App/Alpha.swift", in: root)

        #expect(outcome == .withheld(.overSize), "\(outcome)")
    }
}

extension PagedAnswerTests {
    /// The cursor a page ends with: the member lines it leaves, the offset it says to pass, and how it spells that.
    private struct Cursor {
        let remaining: Int
        let offset: Int
        let spelled: String
    }
}
