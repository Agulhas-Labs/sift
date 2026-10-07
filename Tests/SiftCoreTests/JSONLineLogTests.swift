//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the appender under every ledger this tool keeps.
@Suite(.temporaryDirectories)
struct JSONLineLogTests {
    private static func temporaryLog() throws -> URL {
        let directory = try TemporaryDirectory.make("jsonl")
        return directory.appendingPathComponent("log.jsonl")
    }

    @Test
    func anAppendedEntryIsOneLineOfSortedJSON() throws {
        let fileURL = try Self.temporaryLog()
        let log = JSONLineLog(fileURL: fileURL, subject: "test log")

        log.append(["b": 2, "a": 1])
        let text = try String(contentsOf: fileURL, encoding: .utf8)

        #expect(text == "{\"a\":1,\"b\":2}\n")
    }

    /// Concurrent appenders lose nothing.
    ///
    /// A write that opens the file `O_WRONLY`, seeks to the end and writes loses lines — the offset that seek resolves is stale the moment anything else appends, so under a few concurrent appenders a share of the lines go missing and some arrive malformed. Every file this appender serves is written by several processes at once by construction — one `sift mcp` per session, plus every hook and every wrapped run — so that is ordinary traffic rather than a rare interleaving, and a lost line in the newest of those files makes `sift status` report a clean exit as a crash.
    ///
    /// Threads here rather than processes: the defect is the read-modify-write, and it does not care which kind of concurrency exposes it.
    @Test
    func concurrentAppendsLoseNoLines() throws {
        let fileURL = try Self.temporaryLog()
        let writers = 4
        let each = 200
        let finished = DispatchSemaphore(value: 0)

        for writer in 0 ..< writers {
            let thread = Thread {
                let log = JSONLineLog(fileURL: fileURL, subject: "test log")
                for line in 0 ..< each {
                    log.append(["writer": writer, "line": line])
                }
                finished.signal()
            }
            thread.start()
        }
        for _ in 0 ..< writers {
            finished.wait()
        }

        let data = try Data(contentsOf: fileURL)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        let parsed = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }

        #expect(lines.count == writers * each)
        #expect(parsed.count == writers * each, "every line must be whole JSON, not two writers spliced together")
        // No byte outside a line: a stale offset leaves NUL holes behind.
        #expect(!data.contains(0x00))
    }
}
