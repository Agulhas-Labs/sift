//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A `Grep`'s content search is answered in place only where the answer is smaller than what the search prints, wherever size decides what it asks: a declaration, or a name declared once.
@Suite(.temporaryDirectories)
struct GrepRawSmallerTests {
    /// A package declaring `Ends` once, used on ten lines of another file, and `Widget` on two types, each used once.
    private static func package(extraFiles: [String: String] = [:]) throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let uses = (1 ... 10).map { "    func pick\($0)() -> Ends { .open }\n" }.joined()
        try MCPTestRepo.add([
            "Sources/App/Ends.swift": "enum Ends {\n    case open\n    case shut\n}\n",
            "Sources/App/Picks.swift": "struct Picks {\n" + uses + "}\n",
            "Sources/App/Widgets.swift": "struct Left {\n    struct Widget {}\n    let one = Widget()\n}\n\nstruct Right {\n    struct Widget {}\n    let two = Widget()\n}\n",
        ].merging(extraFiles) { $1 }, to: root)
        return root
    }

    /// What the hook's answerer makes of a content `Grep` of `pattern` from `root`, on a thread of its own, with a deadline that never arrives — or, where asked, one already past for the search's own weighing alone.
    private static func outcome(of pattern: String, in root: URL, weighingOutOfTime: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) async throws -> InPlaceAnswerer.Outcome {
        let match = try #require(InPlaceShape.match(forSearchTool: "Grep", input: ["pattern": pattern, "output_mode": "content"], in: root.path), sourceLocation: sourceLocation)
        let backoff = try InPlaceAnswerTests.backoff()
        let deadline = weighingOutOfTime ? InPlaceDeadline { $0 == SearchToolGrep.timeCap ? .now() : .distantFuture } : .unbounded
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, deadline: deadline, backoff: backoff)
        }
    }

    /// A declaration search whose weighing runs out of time runs unchecked, rather than being answered unweighed.
    @Test
    func aDeclarationSearchOutOfTimeToWeighRuns() async throws {
        let root = try Self.package()

        #expect(try await Self.outcome(of: "enum Ends", in: root, weighingOutOfTime: true) == .withheld(.unchecked))
    }

    /// A name declared once whose weighing runs out of time is still answered: no run on record says which is smaller.
    @Test
    func aNameDeclaredOnceOutOfTimeToWeighIsAnswered() async throws {
        let root = try Self.package()

        guard case .answered = try await Self.outcome(of: "Ends", in: root, weighingOutOfTime: true) else {
            Issue.record("a name declared once was not answered once its weighing ran out of time")
            return
        }
    }

    /// A declaration search printing one line is not answered with a `where` listing every use: the search runs.
    @Test
    func aDeclarationSearchPrintingLessThanItsAnswerRuns() async throws {
        let root = try Self.package()

        #expect(try await Self.outcome(of: "enum Ends", in: root) == .withheld(.notSmaller))
    }

    /// A bare name declared once is weighed too, as a declaration search is.
    @Test
    func aNameDeclaredOncePrintingLessThanItsAnswerRuns() async throws {
        let root = try Self.package()

        #expect(try await Self.outcome(of: "Ends", in: root) == .withheld(.notSmaller))
    }

    /// The same declaration search, printing more than its answer — forty comment lines naming it — is still answered.
    @Test
    func aDeclarationSearchPrintingMoreThanItsAnswerIsAnswered() async throws {
        let comments = (1 ... 40).map { "// note \($0): the enum Ends is spelled here in a comment long enough to weigh more than the answer\n" }.joined()
        let root = try Self.package(extraFiles: ["Sources/App/Notes.swift": comments])

        guard case .answered = try await Self.outcome(of: "enum Ends", in: root) else {
            Issue.record("expected the search to be answered in place")
            return
        }
    }

    /// A bare name two types declare asks which one each use resolves to, so it is answered even where the search prints less.
    @Test
    func aNameDeclaredTwiceIsAnsweredWhateverTheSearchPrints() async throws {
        let root = try Self.package()

        guard case let .answered(answered) = try await Self.outcome(of: "Widget", in: root) else {
            Issue.record("expected the search to be answered in place")
            return
        }
        let printed = "Sources/App/Widgets.swift:2:    struct Widget {}\n".utf8.count * 4

        #expect(answered.reason.utf8.count > printed)
    }

    /// The `Grep` tool's weighed search of `pattern` over a repository holding `files`, with the tool's own `fields` beside the pattern.
    private static func tool(_ files: [String: String], fields: [String: Any] = [:], sourceLocation: SourceLocation = #_sourceLocation) throws -> SearchToolGrep {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add(files, to: root)
        let input = ["pattern": "Gizmo", "output_mode": "content"].merging(fields) { $1 }
        return try #require(SearchToolGrep(input: input, pattern: "Gizmo", searched: nil, in: root.path), sourceLocation: sourceLocation)
    }

    private static func prefix(_ line: Int) -> String {
        "Many.swift:\(line):"
    }

    /// The tool prints 250 lines where it is given no `head_limit`, so six hundred matching lines weigh as 250.
    @Test
    func sixHundredMatchingLinesAreCountedAsTheFirstTwoHundredAndFifty() throws {
        let search = try Self.tool(["Many.swift": String(repeating: "Gizmo\n", count: 600)])

        let bytes = search.printedBytes(answerBytes: .max, deadline: .unbounded)

        #expect(bytes == (1 ... 250).reduce(0) { $0 + Self.prefix($1).utf8.count + "Gizmo\n".utf8.count })
    }

    /// A `head_limit` of 10 counts ten lines; an `offset` of 5 skips five first.
    @Test
    func aHeadLimitAndAnOffsetBoundTheLinesCounted() throws {
        let files = ["Many.swift": String(repeating: "Gizmo\n", count: 600)]
        let limited = try Self.tool(files, fields: ["head_limit": 10])
        let offset = try Self.tool(files, fields: ["head_limit": "10", "offset": 5])

        #expect(limited.printedBytes(answerBytes: .max, deadline: .unbounded) == (1 ... 10).reduce(0) { $0 + Self.prefix($1).utf8.count + 6 })
        #expect(offset.printedBytes(answerBytes: .max, deadline: .unbounded) == (6 ... 15).reduce(0) { $0 + Self.prefix($1).utf8.count + 6 })
    }

    /// A matching line of two thousand characters is not printed whole: its text counts for 500 bytes.
    @Test
    func aLongLineCountsForAtMostFiveHundredBytesOfText() throws {
        let search = try Self.tool(["Many.swift": "Gizmo" + String(repeating: "x", count: 1995) + "\n"])

        let bytes = search.printedBytes(answerBytes: .max, deadline: .unbounded)

        #expect(bytes == Self.prefix(1).utf8.count + 500 + 1)
    }

    /// With an answer of N bytes the search stops once it has printed more than N: the count is just above N, not the whole output.
    @Test
    func theSearchStopsOnceItHasPrintedMoreThanTheAnswer() throws {
        let files = Dictionary(uniqueKeysWithValues: (1 ... 200).map { (String(format: "F%03d.swift", $0), "Gizmo\n") })
        let search = try Self.tool(files)
        let answerBytes = 300
        let ceiling = ShellGrep.Ceiling(admits: { _ in true }, cost: { _, _ in 0 }, budget: 0, printLimit: answerBytes)

        let measured = search.search.measured(in: search.directory, ceiling: ceiling, skipsCache: true, ignoreScope: .withParents)
        let whole = search.printedBytes(answerBytes: .max, deadline: .unbounded)

        #expect(measured.outcome == .pastCeiling(.printsPastLimit))
        #expect(measured.bytes > answerBytes && measured.bytes < answerBytes + 30)
        #expect(search.printedBytes(answerBytes: answerBytes, deadline: .unbounded) == nil)
        let printed = try #require(whole)
        #expect(printed > answerBytes + SearchToolGrep.framingAllowance)
        // An answer whose refusal could still outweigh the search, by up to its framing, has the search measured whole.
        #expect(search.printedBytes(answerBytes: printed - SearchToolGrep.framingAllowance, deadline: .unbounded) == printed)
    }

    private static let sixHundred = ["Many.swift": String(repeating: "Gizmo\n", count: 600)]

    private static func bytes(of lines: ClosedRange<Int>) -> Int {
        lines.reduce(0) { $0 + prefix($1).utf8.count + 6 }
    }

    /// A `head_limit` near `Int.max`, with an `offset`, once trapped the hook adding the two.
    @Test
    func aHeadLimitNearIntMaxAfterAnOffsetDoesNotTrap() throws {
        let search = try Self.tool(Self.sixHundred, fields: ["head_limit": "9223372036854775807", "offset": 1])

        #expect(search.printedBytes(answerBytes: .max, deadline: .unbounded) == Self.bytes(of: 2 ... 600))
    }

    /// An `offset` of `Int.max` skips every line, with or without a limit, and is read without error.
    @Test
    func anOffsetOfIntMaxDoesNotTrapAndKeepsNoLine() throws {
        let limited = try Self.tool(Self.sixHundred, fields: ["offset": "9223372036854775807"])
        let unlimited = try Self.tool(Self.sixHundred, fields: ["offset": "9223372036854775807", "head_limit": 0])

        #expect(limited.printedBytes(answerBytes: .max, deadline: .unbounded) == 0)
        #expect(unlimited.printedBytes(answerBytes: .max, deadline: .unbounded) == 0)
    }

    /// A negative or unparsable count is as good as none: the default window of 250 lines counts.
    @Test
    func aNegativeOrUnparsableCountIsTakenAsAbsent() throws {
        let negative = try Self.tool(Self.sixHundred, fields: ["head_limit": -3, "offset": "-1"])
        let unparsable = try Self.tool(Self.sixHundred, fields: ["head_limit": "many", "offset": "9223372036854775808"])

        #expect(negative.printedBytes(answerBytes: .max, deadline: .unbounded) == Self.bytes(of: 1 ... 250))
        #expect(unparsable.printedBytes(answerBytes: .max, deadline: .unbounded) == Self.bytes(of: 1 ... 250))
    }

    /// The walk stops reading once the window is full: a file after it that cannot be decided (its bytes are not UTF-8) does not leave the search undecided.
    @Test
    func theSearchStopsReadingOnceTheWindowIsFull() throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add(["A.swift": "Gizmo\nGizmo\nGizmo\n"], to: root)
        try Data([0x47, 0x69, 0x7A, 0x6D, 0x6F, 0xFF, 0xFE, 0x0A]).write(to: root.appendingPathComponent("Zz.swift"))
        let two: [String: Any] = ["pattern": "Gizmo", "output_mode": "content", "head_limit": 2]
        let five: [String: Any] = ["pattern": "Gizmo", "output_mode": "content", "head_limit": 5]
        let windowed = try #require(SearchToolGrep(input: two, pattern: "Gizmo", searched: nil, in: root.path))
        let unfilled = try #require(SearchToolGrep(input: five, pattern: "Gizmo", searched: nil, in: root.path))

        let stopped = windowed.search.measured(in: windowed.directory, skipsCache: true, ignoreScope: .withParents)
        let reading = unfilled.search.measured(in: unfilled.directory, skipsCache: true, ignoreScope: .withParents)

        guard case .printed = stopped.outcome else {
            Issue.record("expected the full window to end the walk, got \(stopped.outcome)")
            return
        }
        // The window of five is never full, so the walk reaches the file it cannot decide.
        #expect(reading.outcome == .undecided("encoding") || reading.outcome == .undecided("line"))
    }
}
