//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// `audit --replay --sample N`: a replay bounded to a sample of the window's sessions, chosen the same way whatever order they are listed in, saying what it left out, and telling its progress without changing its report.
@Suite(.temporaryDirectories)
struct ReplaySampleTests {
    /// A sample of two of three sessions replays two, each one's cold lookup counted, and the report says the share is a sample's.
    @Test func aSampleReplaysAtMostItsBoundAndSaysSo() async throws {
        let projects = try Self.projects(sessions: 3)

        let sampled = try await Self.replay(projects, sample: ReplaySample(limit: 2))
        let every = try await Self.replay(projects, sample: .everySession)

        #expect(sampled.report.contains("  cold            2  the lookups the audit calls cold"), "\(sampled.report)")
        #expect(sampled.report.contains { $0.hasPrefix("  sampled 2 of 3 sessions") }, "\(sampled.report)")
        #expect(sampled.progress.count { $0.hasPrefix("replayed ") } == 2, "\(sampled.progress)")
        #expect(every.report.contains("  cold            3  the lookups the audit calls cold"), "\(every.report)")
        #expect(!every.report.contains { $0.contains("sampled") }, "\(every.report)")
    }

    /// The report is the same line for line whether or not anything listens to the progress, and what it was told names each session and the time taken.
    @Test func progressNeverChangesTheReport() async throws {
        let projects = try Self.projects(sessions: 2)

        let told = try await Self.replay(projects, sample: .everySession)
        let silent = try await Self.replay(projects, sample: .everySession, listening: false)

        #expect(told.report == silent.report)
        #expect(told.progress.first?.hasPrefix("replaying 2 sessions,") == true, "\(told.progress)")
        #expect(told.progress.contains { $0.hasPrefix("replayed 2 of 2 sessions (this one 1 context), elapsed ") }, "\(told.progress)")
        #expect(silent.progress.isEmpty)
    }

    /// The command's report hands its sample and its progress to the replay, and the audit above the replay still counts every session.
    @Test func theCommandsReportReplaysItsSampleAndAuditsEverySession() async throws {
        let projects = try Self.projects(sessions: 3)
        let snapshot = TranscriptSnapshot.take(projectsDirectory: projects, since: nil, transcript: nil)
        let (scratch, told) = try (TemporaryDirectory.make("replay"), Told())

        let report = await InPlaceAnswerTests.onItsOwnThread {
            AuditCommand.report(
                snapshot: snapshot,
                projectsDirectory: projects,
                since: nil,
                replay: true,
                scratch: scratch,
                timeBudget: InPlaceAnswerTests.roomy,
                sample: ReplaySample(limit: 1),
                progress: { told.append($0) }
            ).report.components(separatedBy: "\n")
        }

        #expect(report.contains("  cold           3  went around the index  ← the misses"), "\(report)")
        #expect(report.contains { $0.hasPrefix("  sampled 1 of 3 sessions") }, "\(report)")
        #expect(told.all.contains { $0.hasPrefix("replayed 1 of 1 sessions") }, "\(told.all)")
    }

    /// With sessions left out, the `--against` section names its counts the sample's, not the window's; with none left out its words are the window's, as before.
    @Test func theComparisonNamesTheSampleWhenSessionsWereLeftOut() async throws {
        let projects = try Self.projects(sessions: 3)

        let sampled = try await Self.compare(projects, sample: ReplaySample(limit: 2))
        let every = try await Self.compare(projects, sample: .everySession)

        #expect(sampled.contains { $0.contains("every call in the sample put to both hooks") }, "\(sampled)")
        #expect(sampled.contains("  no difference: the two hooks judge all 2 calls in the sample alike"), "\(sampled)")
        #expect(!sampled.contains { $0.contains("in the window") }, "\(sampled)")
        #expect(every.contains { $0.contains("every call in the window put to both hooks") }, "\(every)")
        #expect(every.contains("  no difference: the two hooks judge all 3 calls in the window alike"), "\(every)")
        #expect(ReplayComparison.lines([], sampled: true).contains { $0.contains("in the sample") })
        #expect(ReplayComparison.lines([]).contains { $0.contains("in the window") })
    }

    /// The `--shapes` file's counts are the sample's, so it carries the sample note under its heading where sessions were left out, and is as it was where none were.
    @Test func theShapesFileSaysItsCountsAreTheSamples() async throws {
        let projects = try Self.projects(sessions: 3)

        let sampled = try await Self.shapes(projects, sample: ReplaySample(limit: 2))
        let every = try await Self.shapes(projects, sample: .everySession)

        #expect(sampled.first?.hasPrefix("still cold") == true, "\(sampled)")
        #expect(sampled.dropFirst().first?.hasPrefix("  sampled 2 of 3 sessions") == true, "\(sampled)")
        #expect(!every.contains { $0.contains("sampled") }, "\(every)")
        #expect(ReplaySample.notedShapes(["heading"], replayed: 1, of: 1) == ["heading"])
    }

    /// The bound counts contexts: a first-ranked session whose subagents carry it past the bound is replayed whole and alone, and the note counts the contexts.
    @Test func theBoundCountsContextsAndKeepsTheSessionReachingItWhole() async throws {
        let projects = try Self.projects(orchestrator: 7, subagents: 3, singles: [4, 3, 9])

        let sampled = try await Self.replay(projects, sample: ReplaySample(limit: 3))

        #expect(sampled.progress.count { $0.hasPrefix("replayed ") } == 1, "\(sampled.progress)")
        #expect(sampled.progress.contains { $0.hasPrefix("replayed 1 of 1 sessions (this one 4 contexts)") }, "\(sampled.progress)")
        #expect(sampled.report.contains { $0.hasPrefix("  sampled 1 of 4 sessions (each with its subagents, 4 of 7 contexts)") }, "\(sampled.report)")
    }

    /// A session larger than what is left of the bound is kept, not passed over for the smaller ones ranked after it.
    @Test func aLargeSessionIsNeverPassedOverForSmallerOnes() async throws {
        let projects = try Self.projects(orchestrator: 4, subagents: 3, singles: [7, 3, 9])

        let sampled = try await Self.replay(projects, sample: ReplaySample(limit: 3))

        #expect(sampled.progress.count { $0.hasPrefix("replayed ") } == 2, "\(sampled.progress)")
        #expect(sampled.progress.contains { $0.contains("(this one 4 contexts)") }, "\(sampled.progress)")
        #expect(sampled.report.contains { $0.hasPrefix("  sampled 2 of 4 sessions (each with its subagents, 5 of 7 contexts)") }, "\(sampled.report)")
    }

    /// What the command hands its replay: a hundred contexts where `--sample` is not given, every session for 0, the given bound otherwise, and progress on stderr only when asked or on a terminal.
    @Test func theCommandBoundsItsReplayAndGatesItsProgress() {
        func bounds(_ sample: Int?, asked: Bool = false, terminal: Bool = false) -> (limit: Int?, told: [String]) {
            let recorded = RecordedOutput()
            let chosen = AuditCommand.replayBounds(sample: sample, progressAsked: asked, stderrIsTerminal: terminal, output: recorded.output)
            chosen.progress("replaying")
            return (chosen.sample.limit, recorded.errors)
        }

        #expect(bounds(nil).limit == 100)
        #expect(bounds(0).limit == nil)
        #expect(bounds(4).limit == 4)
        #expect(bounds(nil).told.isEmpty)
        #expect(bounds(nil, asked: true).told == ["audit: replaying"])
        #expect(bounds(nil, terminal: true).told == ["audit: replaying"])
    }

    /// The sample is a function of the sessions' file names, not their order or directory, and keeps the order it was handed.
    @Test func theSampleIsTheSameWhateverOrderTheSessionsCameIn() {
        let sessions = (1 ... 8).map { URL(fileURLWithPath: "/projects/-Users-someone-App/aaaa000\($0)-1111.jsonl") }
        let sample = ReplaySample(limit: 3)

        let forward = sample.chosen(from: sessions)
        let backward = sample.chosen(from: sessions.reversed())
        let moved = sample.chosen(from: sessions.map { URL(fileURLWithPath: "/elsewhere/\($0.lastPathComponent)") })

        #expect(forward.count == 3)
        #expect(Set(forward.map(\.lastPathComponent)) == Set(backward.map(\.lastPathComponent)))
        #expect(forward.map(\.lastPathComponent) == moved.map(\.lastPathComponent))
        #expect(forward == sessions.filter { forward.contains($0) })
        #expect(ReplaySample.everySession.chosen(from: sessions) == sessions)
    }

    /// Only a session holding a lookup inside the window is ranked: sessions with no Swift call, or whose calls all fall after `--until`, leave their places to ones that have some.
    @Test func theSampleRanksOnlySessionsWithAnInWindowLookup() throws {
        func transcript(_ command: String, at stamp: String) throws -> Data {
            try TranscriptAuditReplayTests.call(command, id: "c", cwd: "/repo", at: stamp) + Data([0x0A])
        }
        let swift = try transcript("cat Sources/App/Depot.swift", at: "2026-09-21T10:00:00Z")
        let prose = try transcript("ls", at: "2026-09-21T10:00:00Z")
        let late = try transcript("cat Sources/App/Depot.swift", at: "2026-09-29T10:00:00Z")
        let until = ISO8601DateFormatter().date(from: "2026-09-25T00:00:00Z")

        #expect(ReplaySample.holdsLookup(swift, since: nil, until: until))
        #expect(!ReplaySample.holdsLookup(prose, since: nil, until: until))
        #expect(!ReplaySample.holdsLookup(late, since: nil, until: until))
        #expect(ReplaySample.holdsLookup(late, since: nil, until: nil))

        let sessions = (1 ... 6).map { URL(fileURLWithPath: "/projects/-App/aaaa000\($0)-1111.jsonl") }
        let withLookups = Set(sessions.prefix(2).map(\.path))
        let chosen = ReplaySample(limit: 3).chosen(from: sessions) { withLookups.contains($0.path) }
        #expect(Set(chosen.map(\.path)) == withLookups)
    }

    /// The replay hands the sample the sessions that hold a lookup, so a window mostly of sessions that look up nothing still replays the ones that do.
    @Test func theReplayRanksOnlySessionsHoldingALookup() async throws {
        let root = try TemporaryDirectory.make("projects").appendingPathComponent("projects")
        let project = root.appendingPathComponent("-Users-someone-Developer-App")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let cwd = try TemporaryDirectory.make("repo")
        for index in 1 ... 8 {
            let command = index <= 2 ? "cat Sources/App/Depot.swift" : "ls"
            let lines = try [
                TranscriptAuditReplayTests.call(command, id: "c\(index)", cwd: cwd.path, at: "2026-09-21T10:00:00Z"),
                TranscriptFixture.toolResult(id: "c\(index)", isError: false, text: "struct Depot"),
            ]
            try Data(lines.joined(separator: [0x0A]) + [0x0A]).write(to: project.appendingPathComponent("7777888\(index)-9999.jsonl"))
        }

        let sampled = try await Self.replay(root, sample: ReplaySample(limit: 2))

        #expect(sampled.report.contains("  cold            2  the lookups the audit calls cold"), "\(sampled.report)")
        #expect(sampled.progress.count { $0.hasPrefix("replayed ") } == 2, "\(sampled.progress)")
    }

    /// The note goes under the section's heading, first where `--summary` dropped the heading, and nowhere where nothing was left out.
    @Test func theSampleNoteSitsUnderTheHeading() {
        let full = ["", "replay — heading", "  cold 1"]
        let summary = ["  replayed share 50%"]

        #expect(ReplaySample.noted(full, replayed: 1, of: 2)[2].hasPrefix("  sampled 1 of 2 sessions"))
        #expect(ReplaySample.noted(summary, replayed: 1, of: 2)[0].hasPrefix("  sampled 1 of 2 sessions"))
        #expect(ReplaySample.noted(full, replayed: 2, of: 2) == full)
    }

    /// `--sample` defaults to a bound, 0 lifts it, and it is refused without `--replay` or below zero; `--progress` parses with `--replay` and without it, where it tells the scan alone.
    @Test func theSampleFlagDefaultsToABoundAndZeroLiftsIt() throws {
        #expect(AuditCommand.limit(nil) == AuditCommand.defaultSample)
        #expect(AuditCommand.limit(0) == nil)
        #expect(AuditCommand.limit(4) == 4)
        #expect(try AuditCommand.parse(["--replay", "--sample", "4", "--progress"]).sample == 4)
        #expect(try AuditCommand.parse(["--replay", "--progress"]).progress)
        #expect(throws: (any Error).self) { try AuditCommand.parse(["--sample", "4"]) }
        #expect(throws: (any Error).self) { try AuditCommand.parse(["--replay", "--sample=-1"]) }
        #expect(try AuditCommand.parse(["--progress"]).progress)
    }
}

private extension ReplaySampleTests {
    /// What a replay printed and what it told its progress listener.
    struct Replayed {
        let report: [String]
        let progress: [String]
    }

    /// The lines a replay's progress was told, from whichever thread it ran on.
    final class Told: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.withLock { lines.append(line) }
        }

        var all: [String] {
            lock.withLock { lines }
        }
    }

    /// A projects directory holding `sessions` session transcripts, each with one cold lookup of its own day.
    static func projects(sessions: Int) throws -> URL {
        let root = try TemporaryDirectory.make("projects").appendingPathComponent("projects")
        let project = root.appendingPathComponent("-Users-someone-Developer-App")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let cwd = try TemporaryDirectory.make("repo")
        for index in 1 ... sessions {
            let lines = try [
                TranscriptAuditReplayTests.call("cat Sources/App/Depot.swift", id: "c\(index)", cwd: cwd.path, at: "2026-09-2\(index)T10:00:00Z"),
                TranscriptFixture.toolResult(id: "c\(index)", isError: false, text: "struct Depot"),
            ]
            try Data(lines.joined(separator: [0x0A]) + [0x0A]).write(to: project.appendingPathComponent("1111222\(index)-3333.jsonl"))
        }
        return root
    }

    /// A projects directory holding the session numbered `orchestrator` with `subagents` subagent transcripts, and one session of a single context for each of `singles`, every context with one cold lookup.
    static func projects(orchestrator: Int, subagents: Int, singles: [Int]) throws -> URL {
        let root = try TemporaryDirectory.make("projects").appendingPathComponent("projects")
        let project = root.appendingPathComponent("-Users-someone-Developer-App")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let cwd = try TemporaryDirectory.make("repo")
        func write(_ id: String, to file: URL) throws {
            let lines = try [
                TranscriptAuditReplayTests.call("cat Sources/App/Depot.swift", id: id, cwd: cwd.path, at: "2026-09-21T10:00:00Z"),
                TranscriptFixture.toolResult(id: id, isError: false, text: "struct Depot"),
            ]
            try Data(lines.joined(separator: [0x0A]) + [0x0A]).write(to: file)
        }
        for number in [orchestrator] + singles {
            try write("s\(number)", to: project.appendingPathComponent("4444555\(number)-6666.jsonl"))
        }
        let agents = project.appendingPathComponent("4444555\(orchestrator)-6666/subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        for index in 1 ... subagents {
            try write("a\(index)", to: agents.appendingPathComponent("agent-a\(index).jsonl"))
        }
        return root
    }

    /// The `--against` section of a replay of `projects` against this build's own hook, bounded by `sample`.
    static func compare(_ projects: URL, sample: ReplaySample) async throws -> [String] {
        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: InPlaceAnswerTests.roomy)
        let other = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: InPlaceAnswerTests.roomy)
        return await InPlaceAnswerTests.onItsOwnThread {
            TranscriptReplay.sections(projectsDirectory: projects, since: nil, transcript: nil, hook: hook, against: other, sample: sample).report
        }
    }

    /// The `--shapes` file's lines of a replay of `projects`, bounded by `sample`.
    static func shapes(_ projects: URL, sample: ReplaySample) async throws -> [String] {
        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: InPlaceAnswerTests.roomy)
        return await InPlaceAnswerTests.onItsOwnThread {
            TranscriptReplay.sections(projectsDirectory: projects, since: nil, transcript: nil, hook: hook, sample: sample).shapes
        }
    }

    /// The replay of every session under `projects`, bounded by `sample`, under the roomy budget and on a thread of its own.
    static func replay(_ projects: URL, sample: ReplaySample, listening: Bool = true) async throws -> Replayed {
        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: InPlaceAnswerTests.roomy)
        let told = Told()
        let report = await InPlaceAnswerTests.onItsOwnThread {
            TranscriptReplay.sections(
                projectsDirectory: projects,
                since: nil,
                transcript: nil,
                hook: hook,
                sample: sample,
                progress: listening ? { told.append($0) } : { _ in }
            ).report
        }
        return Replayed(report: report, progress: told.all)
    }
}
