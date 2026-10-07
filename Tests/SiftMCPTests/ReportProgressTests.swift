//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import SiftMCP
import Testing

/// A report over many transcripts says what it is reading while it reads, so a slow run is not mistaken for a stuck one.
@Suite(.temporaryDirectories) struct ReportProgressTests {
    private static func assemble(sessions: Int, progress: @escaping (String) -> Void) throws -> URL {
        let directory = try TemporaryDirectory.make("report-progress")
        let project = directory.appendingPathComponent("projects/-repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        for index in 0 ..< sessions {
            try Data("{}\n".utf8).write(to: project.appendingPathComponent("session-\(index).jsonl"))
        }
        let log = directory.appendingPathComponent("usage.jsonl")
        try Data().write(to: log)
        _ = ReportData.assemble(
            logURL: log,
            projectsDirectory: directory.appendingPathComponent("projects"),
            roots: [],
            since: nil,
            root: nil,
            now: Date(),
            moduleHealth: { _ in nil },
            progress: progress
        )
        return log
    }

    /// Each stage names itself: the log by its path, then the transcript sweep with its size and its finish.
    @Test
    func eachStageIsNamedAsItStarts() throws {
        var lines: [String] = []

        let log = try Self.assemble(sessions: 3) { lines.append($0) }

        #expect(lines.first == "reading the usage log \(log.path)")
        #expect(lines.contains { $0.hasPrefix("scanning 3 session transcripts") })
        #expect(lines.last == "scanned 3 of 3 session transcripts")
    }

    /// A long sweep reports how far it has got, not only that it began.
    @Test
    func aLongSweepReportsItsAdvance() throws {
        var lines: [String] = []

        _ = try Self.assemble(sessions: 120) { lines.append($0) }

        #expect(lines.contains("scanned 50 of 120 session transcripts"))
        #expect(lines.contains("scanned 100 of 120 session transcripts"))
    }
}
