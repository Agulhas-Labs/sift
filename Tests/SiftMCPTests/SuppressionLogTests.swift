//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the suppression log's appending — the record the gate's fire rate is read from.
@Suite(.temporaryDirectories)
struct SuppressionLogTests {
    /// Concurrent writers lose nothing.
    ///
    /// Opening, seeking and writing on its own — the same three steps ``SiftCore/JSONLineLog`` names as losing lines under concurrent writers — would lose lines here too, and this log's writer is the `pre-tool-use` hook, one process per tool call, so concurrent appends are its normal traffic. A lost line here is a withheld denial that never happened as far as the rate can tell, which under-reports exactly the number the log exists to make honest.
    ///
    /// Threads rather than processes, as in the appender's own test: the defect is the stale offset, and it does not care which kind of concurrency exposes it.
    @Test
    func concurrentNotesLoseNoLines() throws {
        let directory = try TemporaryDirectory.make("suppressions")
            .appendingPathComponent("suppressions")
        let fileURL = directory.appendingPathComponent("suppressions.jsonl")
        let writers = 4
        let each = 200
        let finished = DispatchSemaphore(value: 0)

        for writer in 0 ..< writers {
            let thread = Thread {
                let log = SuppressionLog(fileURL: fileURL)
                for line in 0 ..< each {
                    log.note(symbol: "\(writer):\(line)", directory: "/tmp/repo", rule: "gateLeg")
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
        #expect(!data.contains(0x00))
    }
}
