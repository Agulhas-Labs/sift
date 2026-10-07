//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A plain `audit` tells its own transcript scan as it goes, on stderr and under the replay's rule, and prints the same report whether or not anything listens.
@Suite(.temporaryDirectories)
struct AuditScanProgressTests {
    /// The scan says it began over how many sessions and that it finished, and the report is byte for byte the one printed with nothing listening.
    @Test func aPlainAuditTellsItsScanWithoutChangingTheReport() throws {
        let projects = try Self.projects(sessions: 2)
        var told: [String] = []

        let listened = Self.audit(projects) { told.append($0) }
        let silent = Self.audit(projects) { _ in }

        #expect(Data(listened.utf8) == Data(silent.utf8))
        #expect(listened.contains("went around the index"), "\(listened)")
        #expect(told.first?.hasPrefix("scanning 2 session transcripts") == true, "\(told)")
        #expect(told.last == "scanned 2 of 2 session transcripts", "\(told)")
    }

    /// A scan over more than fifty sessions says how far it has got every fifty, as the report's sweep does.
    @Test func aLongScanTellsItsAdvance() throws {
        let projects = try Self.projects(sessions: 60, lookups: false)
        var told: [String] = []

        _ = Self.audit(projects) { told.append($0) }

        #expect(told.contains("scanned 50 of 60 session transcripts"), "\(told)")
        #expect(told.last == "scanned 60 of 60 session transcripts", "\(told)")
    }

    /// The command's progress goes to stderr, prefixed `audit: `, on a terminal or with `--progress` and nowhere otherwise, and leaves stdout as it was.
    @Test func theScansProgressGoesToStderrOnlyWhenTold() throws {
        let projects = try Self.projects(sessions: 2)
        func run(asked: Bool, terminal: Bool) -> (report: String, recorded: RecordedOutput) {
            let recorded = RecordedOutput()
            let bounds = AuditCommand.replayBounds(sample: nil, progressAsked: asked, stderrIsTerminal: terminal, output: recorded.output)
            return (Self.audit(projects, progress: bounds.progress), recorded)
        }

        let asked = run(asked: true, terminal: false)
        let terminal = run(asked: false, terminal: true)
        let captured = run(asked: false, terminal: false)

        #expect(asked.recorded.errors.first?.hasPrefix("audit: scanning 2 session transcripts") == true, "\(asked.recorded.errors)")
        #expect(asked.recorded.errors.last == "audit: scanned 2 of 2 session transcripts", "\(asked.recorded.errors)")
        #expect(terminal.recorded.errors == asked.recorded.errors)
        #expect(captured.recorded.errors.isEmpty, "\(captured.recorded.errors)")
        #expect(asked.recorded.printed.isEmpty && terminal.recorded.printed.isEmpty)
        #expect(Data(asked.report.utf8) == Data(captured.report.utf8))
    }

    /// With `--replay` the audit's own scan is told before the replay's sessions are.
    @Test func theReplaysAuditTellsItsScanFirst() async throws {
        let projects = try Self.projects(sessions: 2)
        let snapshot = TranscriptSnapshot.take(projectsDirectory: projects, since: nil, transcript: nil)
        let scratch = try TemporaryDirectory.make("replay")
        let told = Told()

        _ = await InPlaceAnswerTests.onItsOwnThread {
            AuditCommand.report(
                snapshot: snapshot,
                projectsDirectory: projects,
                since: nil,
                replay: true,
                scratch: scratch,
                timeBudget: InPlaceAnswerTests.roomy,
                progress: { told.append($0) }
            )
        }

        let lines = told.all
        let scanned = try #require(lines.firstIndex(of: "scanned 2 of 2 session transcripts"), "\(lines)")
        let replaying = try #require(lines.firstIndex { $0.hasPrefix("replaying ") }, "\(lines)")

        #expect(scanned < replaying, "\(lines)")
    }
}

private extension AuditScanProgressTests {
    /// The lines a progress listener was told, from whichever thread it ran on.
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

    /// The plain audit of every session under `projects`, its progress told to `progress`.
    static func audit(_ projects: URL, progress: @escaping (String) -> Void) -> String {
        let snapshot = TranscriptSnapshot.take(projectsDirectory: projects, since: nil, transcript: nil)
        return AuditCommand.report(snapshot: snapshot, projectsDirectory: projects, since: nil, progress: progress).report
    }

    /// A projects directory holding `sessions` session transcripts, each with one cold lookup where `lookups`, an empty line otherwise.
    static func projects(sessions: Int, lookups: Bool = true) throws -> URL {
        let root = try TemporaryDirectory.make("projects").appendingPathComponent("projects")
        let project = root.appendingPathComponent("-Users-someone-Developer-App")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let cwd = try TemporaryDirectory.make("repo")
        for index in 1 ... sessions {
            let lines = try lookups ? [
                TranscriptAuditReplayTests.call("cat Sources/App/Depot.swift", id: "c\(index)", cwd: cwd.path, at: "2026-09-2\(index)T10:00:00Z"),
                TranscriptFixture.toolResult(id: "c\(index)", isError: false, text: "struct Depot"),
            ] : [Data("{}".utf8)]
            try Data(lines.joined(separator: [0x0A]) + [0x0A]).write(to: project.appendingPathComponent("1111222\(index)-3333.jsonl"))
        }
        return root
    }
}
