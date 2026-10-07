//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// When a run's progress file ends relative to the ledger write the Stop gate reads in its place.
@Suite(.temporaryDirectories)
struct RunProgressFinishOrderTests {
    /// The file ends only once the green build is on record: a stop between the two would find neither a live run nor a record, and block for a build already done.
    @Test
    func theProgressFileEndsAfterTheGreenBuildIsRecorded() throws {
        let directory = try TemporaryDirectory.make("run-progress-finish-order")
        defer { try? FileManager.default.removeItem(at: directory) }
        let swift = directory.appendingPathComponent("swift")
        try "#!/bin/sh\necho 'Build complete!'\nexit 0\n".write(to: swift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
        var command = try RunCommand.parse(["--", swift.path, "build"])
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory
        let builds = RunLedger(fileURL: SiftPaths.cache(in: directory).appendingPathComponent("green-builds.json"))
        let seen = Seen()
        command.environment = [:]
        command.finishProgress = { progress, exitCode, logPath in
            seen.set(builds.records().count)
            progress.finish(exitCode: exitCode, logPath: logPath)
        }

        try command.run()

        #expect(seen.value == 1, "records on file when the progress file ended: \(String(describing: seen.value))")
    }
}

private extension RunProgressFinishOrderTests {
    /// The count the finish saw, handed back out of a closure.
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var count: Int?

        var value: Int? {
            lock.withLock { count }
        }

        func set(_ count: Int) {
            lock.withLock { self.count = count }
        }
    }
}
