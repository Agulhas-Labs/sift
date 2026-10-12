//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// `sift run` keeps a failed run's log until the same command passes, and every `raw:` line says how long its log lives.
@Suite(.temporaryDirectories)
struct RunFailedLogRetentionTests {
    private func run(_ swift: URL, in directory: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> Answer {
        let recorded = RecordedOutput()
        var command = try RunCommand.parse(["--", swift.path, "build"])
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory
        command.output = recorded.output
        var exit: Int32 = 0
        do {
            try command.run()
        } catch let code as ExitCode {
            exit = code.rawValue
        }
        let raw = try #require(recorded.printed.split(separator: "\n").first { $0.hasPrefix("raw: ") }, sourceLocation: sourceLocation)
        let named = try #require((raw.components(separatedBy: " · ").last ?? "").split(separator: " ").first, sourceLocation: sourceLocation).split(separator: "/").last
        return Answer(raw: String(raw), named: String(named ?? ""), exit: exit)
    }

    @Test
    func aFailedRunsLogLivesUntilTheSameCommandPasses() throws {
        let directory = try TemporaryDirectory.make("run-failed-log-retention")
        defer { try? FileManager.default.removeItem(at: directory) }
        let flag = directory.appendingPathComponent("pass")
        let swift = directory.appendingPathComponent("swift")
        try "#!/bin/sh\nif [ -e \"\(flag.path)\" ]; then echo Build complete!; exit 0; fi\necho 'error: boom'\nexit 1\n"
            .write(to: swift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
        let runs = SiftPaths.cache(in: directory).appendingPathComponent(RunLog.runsDirectoryName, isDirectory: true)

        let failed = try run(swift, in: directory)
        #expect(failed.exit == 1)
        #expect(failed.raw.hasSuffix("kept until it passes or \(RunLog.keptLogs) newer failures"), "\(failed.raw)")
        for _ in 0 ..< RunLog.keptLogs {
            RunLog.open(inDirectory: directory)?.close()
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: runs.path).contains(failed.named))

        try "".write(to: flag, atomically: true, encoding: .utf8)
        let passed = try run(swift, in: directory)
        #expect(passed.exit == 0)
        #expect(passed.raw.hasSuffix("kept for the next \(RunLog.keptLogs - 1) runs"), "\(passed.raw)")
        #expect(try !FileManager.default.contentsOfDirectory(atPath: runs.path).contains(failed.named))
    }
}

private extension RunFailedLogRetentionTests {
    struct Answer {
        let raw: String
        let named: String
        let exit: Int32
    }
}
