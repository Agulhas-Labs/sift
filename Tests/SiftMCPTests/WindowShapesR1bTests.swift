//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// The window spellings beyond a single `sed -n a,bp` — several ranges in one script, `tail -n +N | head`, `nl -ba | sed -n`, an `awk` picking lines by number — are placed and judged exactly as that plain window is, at the hook and in the scan.
@Suite(.temporaryDirectories)
struct WindowShapesR1bTests {
    /// Each family's spellings, with the lines of a long file each prints.
    static let shapes: [(command: String, lines: [Int])] = [
        ("sed -n '10,60p;80,90p' Sources/App/Shell.swift", Array(10 ... 60) + Array(80 ... 90)),
        ("sed -n -e 10,60p -e 80,90p Sources/App/Shell.swift", Array(10 ... 60) + Array(80 ... 90)),
        ("tail -n +100 Sources/App/Shell.swift | head -n 40", Array(100 ... 139)),
        ("tail -n +100 Sources/App/Shell.swift | head -40", Array(100 ... 139)),
        ("nl -ba Sources/App/Shell.swift | sed -n 10,60p", Array(10 ... 60)),
        ("awk 'NR>=10&&NR<=60' Sources/App/Shell.swift", Array(10 ... 60)),
        ("awk 'NR>=10 && NR<=60' Sources/App/Shell.swift", Array(10 ... 60)),
        ("awk 'NR==10,NR==60' Sources/App/Shell.swift", Array(10 ... 60)),
    ]

    /// One spelling per family just outside it — a script that does more than print ranges, a count that is not literal, a numbering that is not `-ba` or a script that searches, an action that prints a field — none of which the hook answers in place as a window.
    static let outside = [
        "sed -n '10,60p;s/count/total/p' Sources/App/Shell.swift",
        "tail -n +$START Sources/App/Shell.swift | head -n 40",
        "nl -ba Sources/App/Shell.swift | sed -n '/part/p'",
        "nl -ba Sources/App/Shell.swift Sources/App/Alpha.swift | sed -n 10,60p",
        "nl -v 5 Sources/App/Shell.swift | sed -n 10,60p",
        "awk 'NR>=10&&NR<=60 {print $1}' Sources/App/Shell.swift",
    ]

    /// Cold, each spelling is answered in place with its file's digest, carrying the window read to the lines the spelling prints.
    @Test(arguments: shapes)
    func aColdShapeIsAnsweredInPlaceWithItsFilesDigest(command: String, lines: [Int]) throws {
        let fixture = try Fixture()
        try fixture.lengthen()
        let lookup = try fixture.classified(command: command)
        let match = try #require(lookup.inPlace, "\(command)")

        guard case let .fileDigest(path, windows) = match.call else {
            Issue.record("expected a file digest, got \(match.call)")
            return
        }
        #expect(path == "Sources/App/Shell.swift")
        let rows = try String(contentsOfFile: fixture.file, encoding: .utf8).components(separatedBy: "\n").dropLast()
        #expect(windows.count == 1)
        #expect(windows.first?.lines(in: Array(rows)) == lines)
        #expect(fixture.verdict(lookup, session: "cold-\(command.hashValue)").token == "in-place")
    }

    /// Once the context holds the file's digest, each spelling is no lookup at all — let through with nothing noted, as the plain window is.
    @Test(arguments: shapes)
    func aShapeOfADigestedFileIsNoLookup(command: String, lines _: [Int]) throws {
        let fixture = try Fixture()
        try fixture.lengthen()
        fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Shell.swift"])

        #expect(try fixture.verdict(fixture.classified(command: command)).line == "allowed\t\tnoLookup", "\(command)")
        #expect(try fixture.verdict(fixture.classified(command: "LC_ALL=C " + command)).line == "allowed\t\tnoLookup", "\(command)")
        #expect(!FileManager.default.fileExists(atPath: fixture.stores.appendingPathComponent("suppressions.jsonl").path))
    }

    /// The real answerer serves each spelling from the file's digest — bounded to the members each range overlaps, one call a range, since the whole digest is over the budget — priced against the lines it prints.
    @Test(arguments: shapes)
    func theAnswererServesEachShapeTheDigest(command: String, lines: [Int]) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        // Every line is padded, so what the members answer saves on each window clears the floor a window whose lines it does not show is held to.
        let depot = root.appendingPathComponent("Sources/App/Depot.swift")
        let padded = try String(contentsOf: depot, encoding: .utf8).components(separatedBy: "\n")
            .map { $0.isEmpty ? $0 : $0 + " // " + String(repeating: "x", count: 160) }
        try padded.joined(separator: "\n").write(to: depot, atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        let written = command.replacingOccurrences(of: "Shell.swift", with: "Depot.swift")
        let match = try #require(InPlaceShape.match(forShell: written, in: root.path))
        let rows = try String(contentsOf: root.appendingPathComponent("Sources/App/Depot.swift"), encoding: .utf8).components(separatedBy: "\n")
        let source = lines.reduce(0) { $0 + rows[$1 - 1].utf8.count + 1 }
        let backoff = try InPlaceAnswerTests.backoff()

        let outcome = await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }

        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer to \(written), got \(outcome)")
            return
        }

        #expect(!answered.calls.isEmpty && answered.calls.allSatisfy { $0.target.hasPrefix("Sources/App/Depot.swift") }, "\(answered.calls)")
        #expect(answered.calls.compactMap(\.bytes.source).reduce(0, +) == source)
    }

    /// The scan scores each spelling as it scores the plain window of the same file: cold where nothing located the file, guided after a digest of it.
    @Test(arguments: shapes)
    func theScanScoresEachShapeAsThePlainWindow(command: String, lines _: [Int]) {
        let plain = "sed -n 10,60p Sources/App/Shell.swift"
        let digest = TranscriptFixture.answeredDigest("Sources/App/Shell.swift", id: "d1", file: "Sources/App/Shell.swift")
        func scored(_ bash: String, after earlier: [Data]) -> [SwiftLookup] {
            TranscriptFixture.lookups(
                earlier + [TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": bash], cwd: "/repo")],
                belowFloor: { _ in false }
            )
        }

        #expect(scored(plain, after: []) == [.cold(file: "Sources/App/Shell.swift", missed: nil)])
        #expect(scored(command, after: []) == scored(plain, after: []), "\(command)")
        #expect(scored(plain, after: digest) == [.indexed, .guided(file: "Sources/App/Shell.swift")])
        #expect(scored(command, after: digest) == scored(plain, after: digest), "\(command)")
    }

    /// A spelling just outside a family is not answered in place as a window, and the scan does not read it as one where it did not before.
    @Test(arguments: outside)
    func aShapeOutsideTheFamiliesIsNotAnsweredAsAWindow(command: String) throws {
        let fixture = try Fixture()
        try fixture.lengthen()

        let lookup = PreToolUseCommand.lookup(command: command, payload: [:], in: fixture.repo.path, noting: fixture.suppressions, couldAnswer: { _, _ in true })

        #expect(lookup?.inPlace == nil, "\(command)")
    }

    /// The numbering stage alone, and piped into anything but a window, is no window and no lookup the hook answers — the family is `nl -ba` into windows and nothing else.
    @Test(arguments: [
        "nl -ba Sources/App/Shell.swift",
        "nl -ba Sources/App/Shell.swift | grep part",
        "nl -ba Sources/App/Shell.swift | sort | sed -n 10,60p",
    ])
    func theNumberingStageIsAWindowOnlyInFrontOfWindows(command: String) throws {
        let fixture = try Fixture()
        try fixture.lengthen()

        #expect(ShellAdvice.windowedReadPaths(command, holdsSource: nil).isEmpty, "\(command)")
        #expect(PreToolUseCommand.lookup(command: command, payload: [:], in: fixture.repo.path, noting: fixture.suppressions, couldAnswer: { _, _ in true })?.inPlace == nil)
    }

    /// A working directory that is a symbolic link, with no `cd` on the line, places a climbing window's file where the link points, as the in-place match does, not beside the link as the path reads.
    @Test func aWindowFromALinkedWorkingDirectoryIsPlacedWhereTheLinkPoints() throws {
        let root = try TemporaryDirectory.make("r1b-link")
        let reached = root.appendingPathComponent("Other/Sources/App")
        try FileManager.default.createDirectory(at: reached, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Other/Deep"), withIntermediateDirectories: true)
        try "struct Shell {}\n".write(to: reached.appendingPathComponent("Shell.swift"), atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("Other/Deep"))

        let paths = ShellAdvice.windowedReadPaths("sed -n '1,30p' ../Sources/App/Shell.swift", holdsSource: nil, cwd: link.path)

        #expect(paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == [reached.appendingPathComponent("Shell.swift").resolvingSymlinksInPath().path])
        #expect(paths.first?.contains("/Link/") == false)
    }
}

private extension WindowShapesR1bTests {
    /// A repository holding `Shell.swift`, and every store the hook writes, somewhere this test owns.
    struct Fixture {
        let repo: URL
        let stores: URL

        init() throws {
            repo = try MCPTestRepo.make(declaring: "Shell")
            stores = try TemporaryDirectory.make("r1b-stores")
        }

        var file: String {
            repo.appendingPathComponent("Sources/App/Shell.swift").path
        }

        var ledger: AdviceLedger {
            AdviceLedger(directory: stores.appendingPathComponent("advice"))
        }

        var suppressions: SuppressionLog {
            SuppressionLog(fileURL: stores.appendingPathComponent("suppressions.jsonl"))
        }

        func context(_ session: String) -> AdviceContext {
            AdviceContext.resolve(sessionID: session, transcriptPath: nil, agentID: "a1")
        }

        /// The hook seeing an index call made in session `s1`, agent `a1`.
        func take(tool: String, input: [String: Any]) {
            _ = PreToolUseCommand.adviceTaken(
                session: "s1",
                context: context("s1"),
                payload: ["tool_name": tool, "tool_input": input, "agent_id": "a1"],
                cwd: repo.path,
                ledger: ledger,
                callers: CallAttribution(directory: stores.appendingPathComponent("callers"))
            )
        }

        /// Makes `Shell.swift` long enough — 163 lines — that its digest is worth offering and every window here falls inside it.
        func lengthen() throws {
            let members = (1 ... 40).map { "    func part\($0)() -> Int {\n        let count = \($0)\n        return count * 2\n    }" }
            try ("/// The test type.\nstruct Shell {\n" + members.joined(separator: "\n") + "\n}\n")
                .write(to: repo.appendingPathComponent("Sources/App/Shell.swift"), atomically: true, encoding: .utf8)
        }

        /// The hook's own classification of a shell command run in the repository.
        func classified(command: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> PreToolUseCommand.Lookup {
            try #require(
                PreToolUseCommand.lookup(command: command, payload: [:], in: repo.path, noting: suppressions, couldAnswer: { _, _ in true }),
                sourceLocation: sourceLocation
            )
        }

        /// The hook's decision on `lookup` in `session`, agent `a1`, with an answerer that always answers in place.
        func verdict(_ lookup: PreToolUseCommand.Lookup, session: String = "s1") -> PreToolUseCommand.Verdict {
            let answered = InPlaceAnswerer.Answered(
                reason: "answered",
                calls: [InPlaceAnswerer.Call(tool: "digest", target: "Sources/App/Shell.swift", bytes: AnswerBytes(served: 1, source: 2))],
                root: repo.path,
                milliseconds: 1
            )
            return PreToolUseCommand.outcome(
                to: lookup,
                session: session,
                context: context(session),
                payload: ["agent_id": "a1"],
                cwd: repo.path,
                ledger: ledger,
                usage: UsageLog(fileURL: stores.appendingPathComponent("usage.jsonl")),
                suppressions: suppressions,
                answerer: { _, _, _ in .answered(answered) }
            ).verdict
        }
    }
}
