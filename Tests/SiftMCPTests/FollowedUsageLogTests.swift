//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A replay follows its usage log rather than reading the tail afresh for every call it judges, and each question still sees what a fresh read of the tail would have shown it.
@Suite(.temporaryDirectories)
struct FollowedUsageLogTests {
    /// A repository for the replayed reads to be in: a directory holding a `.git`.
    private static func repository() throws -> URL {
        let root = try TemporaryDirectory.make("followed-repo")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        return root
    }

    /// What these tests state the index would resolve a bare name to: one file per type, under the app's sources.
    private static func resolve(_ target: String, atRoot _: String) -> String? {
        "Sources/App/\(target).swift"
    }

    private static func recordDigest(of target: String, in hook: HookReplay, root: URL, session: String = "session-1") {
        hook.usage.record(
            tool: "digest",
            target: target,
            root: root.path,
            milliseconds: 0,
            succeeded: true,
            answer: AnswerBytes(served: 1, source: 2),
            session: session
        )
    }

    /// A digest the replay's log gains between two questions is seen by the second: following the log never stops at what it held when first read.
    @Test
    func aLineAppendedBetweenTwoQuestionsIsSeenByTheSecond() throws {
        let root = try Self.repository()
        let hook = try HookReplay(directory: TemporaryDirectory.make("followed-replay"), timeBudget: InPlaceAnswerTests.roomy)
        let path = root.appendingPathComponent("Sources/App/SummaryState.swift").path

        Self.recordDigest(of: "CatalogueStore", in: hook, root: root)
        #expect(!hook.digested.contains(path, session: "session-1", agent: nil, resolve: Self.resolve))

        Self.recordDigest(of: "SummaryState", in: hook, root: root, session: "session-2")
        Self.recordDigest(of: "SummaryState", in: hook, root: root)
        #expect(hook.digested.contains(path, session: "session-1", agent: nil, resolve: Self.resolve))
        #expect(hook.digested.locates(path, session: "session-2", agent: nil, resolve: Self.resolve))
    }

    /// Each byte of the replay's log is read once, however many questions are asked of it and however it grows between them.
    @Test
    func eachByteOfTheReplaysLogIsReadOnce() throws {
        let root = try Self.repository()
        let directory = try TemporaryDirectory.make("followed-replay")
        let hook = HookReplay(directory: directory, timeBudget: InPlaceAnswerTests.roomy)
        let path = root.appendingPathComponent("Sources/App/SummaryState.swift").path

        for round in 0 ..< 5 {
            Self.recordDigest(of: "CatalogueStore", in: hook, root: root, session: "session-\(round)")
            for _ in 0 ..< 3 {
                _ = hook.digested.locates(path, session: "session-1", agent: nil, resolve: Self.resolve)
            }
        }

        let size = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("usage.jsonl").path)[.size] as? Int

        #expect(size != nil)
        #expect(hook.digested.bytesFollowed == size)
    }

    /// Over a log much longer than the tail, growing a line at a time and cut at every kind of place, the followed lines of each session are the ones a fresh read of the tail finds for it.
    @Test
    func theFollowedTailHoldsWhatAFreshReadOfItHolds() throws {
        let url = try TemporaryDirectory.make("followed-log").appendingPathComponent("usage.jsonl")
        let limit = 300
        let follower = UsageLogFollower(fileURL: url, limit: limit)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        let sessions = ["session-1", "session-2"]
        for index in 0 ..< 120 {
            let session = sessions[index % 3 == 0 ? 1 : 0]
            let tool = ["digest", "where", "run"][index % 3]
            let padding = String(repeating: "x", count: index * 7 % 41)
            var line = #"{"tool":"\#(tool)","target":"T\#(index)","session":"\#(session)","pad":"\#(padding)""#
            line += index % 5 == 0 ? #","located":["a.swift"]}"# : "}"
            // Every seventh line is written in two halves, so a question finds it cut off mid-write before it is whole.
            let bytes = Data((line + "\n").utf8)
            if index % 7 == 0 {
                try handle.write(contentsOf: bytes.prefix(bytes.count / 2))
                try expectSameLines(follower, url, limit, sessions)
                try handle.write(contentsOf: bytes.dropFirst(bytes.count / 2))
            } else {
                try handle.write(contentsOf: bytes)
            }
            try expectSameLines(follower, url, limit, sessions)
        }
    }

    private func expectSameLines(
        _ follower: UsageLogFollower,
        _ url: URL,
        _ limit: Int,
        _ sessions: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let tail = DigestedFiles.tail(of: url, bytes: limit) ?? Data()
        for session in sessions {
            let fresh = tail.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap { line -> String? in
                guard line.range(of: Data(session.utf8)) != nil,
                      line.range(of: Data(#""digest""#.utf8)) != nil || line.range(of: Data(#""located""#.utf8)) != nil,
                      let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      entry["session"] as? String == session
                else { return nil }
                return entry["target"] as? String
            }
            let followed = follower.lines(of: session)?.compactMap { $0.entry["target"] as? String }
            #expect(followed == fresh, sourceLocation: sourceLocation)
        }
    }
}
