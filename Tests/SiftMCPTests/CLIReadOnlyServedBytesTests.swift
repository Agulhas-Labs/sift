//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// In a tree nobody may write the index lives in memory and the answer says so; the usage log's served bytes count that note, because they are the bytes that went out.
@Suite(.temporaryDirectories)
struct CLIReadOnlyServedBytesTests {
    @Test
    func theLoggedServedBytesIncludeTheInMemoryIndexNote() async throws {
        let repo = try await InPlaceAnswerTests.indexedRepository()
        let scratch = try CLIUsageLogTests.scratch()
        let log = scratch.appendingPathComponent("usage.jsonl")
        try Self.chmod("-R", "a-w", repo)
        defer { try? Self.chmod("-R", "a+w", repo) }

        let printed = try CLIUsageLogTests.run(["digest", "Depot"], in: repo, usageLog: log, home: scratch)
        let records = CLIUsageLogTests.records(in: log)
        #expect(printed.contains(SiftEngine.inMemoryIndexNoteOpening), "\(printed)")
        let record = try #require(records.first)
        // `emit`'s trailing newline aside, as in the writable case.
        #expect(record["outBytes"] as? Int == printed.utf8.count - 1)
    }

    private static func chmod(_ flag: String, _ mode: String, _ root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = [flag, mode, root.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
