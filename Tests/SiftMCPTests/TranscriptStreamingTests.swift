//
// Copyright © Agulhas Labs
//

import Foundation
import os
import SiftCore
@testable import SiftMCP
import Testing

/// Covers how an audit reads its transcripts: a scan a line at a time as it gets there, never the whole file up front, and the same lines a whole read split at its newlines would give; the working-directory probe without leaving its reads to the caller's pool.
@Suite(.temporaryDirectories)
struct TranscriptStreamingTests {
    /// The tail of a long transcript is read only once the scan reaches it: a read named on the last line, rewritten on disk while the scan is still on the first, is seen as rewritten.
    @Test
    func aScanReadsItsTranscriptAsItGoes() throws {
        let directory = try TemporaryDirectory.make("streaming")
        let transcript = directory.appendingPathComponent("session.jsonl")
        let opening = "/repo/Sources/App/Opening.swift"
        // Megabytes of lines the scan skips on their bytes alone, between the two reads.
        let filler = Data(#"{"type":"user","message":{"content":"\#(String(repeating: "x", count: 10000))"}}"#.utf8)
        let lines = [read(opening, id: "r0")] + Array(repeating: filler, count: 400) + [read("/repo/Sources/App/Closing.swift", id: "r1")]
        try Data(lines.joined(separator: Data([0x0A]))).write(to: transcript)

        let asked = askedPaths(scanning: transcript, in: directory) { path in
            if path == opening {
                rewriteLast("Closing", as: "Rewrote", in: transcript)
            }
        }

        #expect(asked == [opening, "/repo/Sources/App/Rewrote.swift"], "the scan had read the transcript's last line before it handled its first")
    }

    /// The lines read are the ones a split of the whole file gives: empty lines dropped, a line longer than a read's chunk whole, the last line kept without a newline, and nothing written after the snapshot was taken.
    @Test
    func aScanReadsTheSameLinesAWholeReadSplitWould() throws {
        let directory = try TemporaryDirectory.make("streaming")
        let transcript = directory.appendingPathComponent("session.jsonl")
        // A line longer than the chunks the file is read in, which a split at a chunk's edge would leave unparsed.
        let long = TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/Long.swift", "padding": String(repeating: "x", count: 1_000_000)])
        let lines = [Data(), read("/repo/Sources/App/First.swift", id: "r0"), Data(), Data(), long, read("/repo/Sources/App/Last.swift", id: "r2")]
        try Data(lines.joined(separator: Data([0x0A]))).write(to: transcript)
        let snapshot = TranscriptSnapshot.take(projectsDirectory: directory, since: nil, transcript: transcript.path)
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x0A]) + read("/repo/Sources/App/Later.swift", id: "r3"))
        try handle.close()

        let asked = askedPaths(scanning: transcript, in: directory, snapshot: snapshot) { _ in }

        #expect(asked == ["/repo/Sources/App/First.swift", "/repo/Sources/App/Long.swift", "/repo/Sources/App/Last.swift"])
    }

    /// The working-directory probe drains what it read before it returns, measured in a child process that runs nothing else.
    ///
    /// The sweep probes every transcript in the window on one thread whose pool drains only when the audit ends, so whatever a probe leaves to it stays resident for the whole run; the count is of the whole process's heap, so only a process of its own keeps other suites out of it.
    @Test
    func probingAWorkingDirectoryLeavesNothingToTheCallersPool() async {
        await #expect(processExitsWith: .success) {
            try PoolScenario.perform()
        }
    }

    /// Every way a file's bytes can fall across reads gives the lines a whole-file split gives.
    @Test(arguments: [1, 2, 3, 5, 7, 64, TranscriptLines.chunkSize])
    func chunkedLinesEqualTheWholeFileSplit(chunkSize: Int) throws {
        let directory = try TemporaryDirectory.make("streaming")
        let samples: [(name: String, bytes: Data)] = [
            ("two-byte character", Data("{\"a\":\"é\"}\n{\"b\":\"éé\"}\n".utf8)),
            ("four-byte character", Data("{\"a\":\"😀\"}\n😀😀\nx".utf8)),
            ("CRLF endings", Data("{\"a\":1}\r\n{\"b\":2}\r\n\r\n{\"c\":3}\r\n".utf8)),
            ("no trailing newline", Data("{\"a\":1}\n{\"b\":2}".utf8)),
            ("consecutive empty lines", Data("\n\n{\"a\":1}\n\n\n\n{\"b\":2}\n\n".utf8)),
            ("only newlines", Data("\n\n\n".utf8)),
            ("empty file", Data()),
            ("single line", Data("{\"a\":1}".utf8)),
        ]
        for (name, bytes) in samples {
            #expect(try lines(of: bytes, chunkSize: chunkSize, in: directory) == wholeFileSplit(bytes), "\(name) at chunk size \(chunkSize)")
        }
    }

    /// Content built around the real chunk size, with multi-byte characters and newlines on, just before and just after the boundary, and a line longer than a chunk.
    @Test(arguments: -4 ... 4)
    func linesAroundTheChunkBoundaryEqualTheWholeFileSplit(offset: Int) throws {
        let directory = try TemporaryDirectory.make("streaming")
        let chunk = TranscriptLines.chunkSize
        let lead = String(repeating: "a", count: chunk + offset)
        let samples = [
            Data((lead + "é" + "\nnext\n").utf8),
            Data((lead + "😀" + "\nnext").utf8),
            Data((lead + "\r\nnext\r\n").utf8),
            Data((lead + "\n\n\nnext").utf8),
            Data(String(repeating: "é", count: chunk * 3 / 2 + offset).utf8),
        ]
        for bytes in samples {
            #expect(try lines(of: bytes, chunkSize: chunk, in: directory) == wholeFileSplit(bytes), "offset \(offset)")
        }
    }

    /// A file that grew after the snapshot is read only to the size recorded then, as the whole read was.
    @Test(arguments: [1, 3, TranscriptLines.chunkSize])
    func linesAreBoundedByTheRecordedSize(chunkSize: Int) throws {
        let directory = try TemporaryDirectory.make("streaming")
        let transcript = directory.appendingPathComponent("session.jsonl")
        let before = Data("{\"a\":\"é\"}\n{\"b\":2}\n{\"c\"".utf8)
        try before.write(to: transcript)
        let snapshot = TranscriptSnapshot.take(projectsDirectory: directory, since: nil, transcript: transcript.path)
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(":3}\n{\"d\":4}\n".utf8))
        try handle.close()

        let limit = try #require(snapshot.sizes[transcript.path])
        let streamed = try #require(TranscriptLines(url: transcript, limit: limit, chunkSize: chunkSize))
        let whole = try #require(snapshot.contents(of: transcript))

        #expect(whole == before)
        #expect(Array(streamed) == wholeFileSplit(whole))
    }

    /// The lines a scan was given before it streamed: the file's bytes split at newlines, empty pieces dropped.
    private func wholeFileSplit(_ bytes: Data) -> [Data] {
        bytes.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    /// The lines the streaming reader gives for a file holding `bytes`, read `chunkSize` bytes at a time.
    private func lines(of bytes: Data, chunkSize: Int, in directory: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> [Data] {
        let file = directory.appendingPathComponent("lines.jsonl")
        try bytes.write(to: file)
        let lines = try #require(TranscriptLines(url: file, limit: nil, chunkSize: chunkSize), sourceLocation: sourceLocation)
        return Array(lines)
    }

    /// A whole-file `Read` of `path`, which the scan asks the floor about.
    private func read(_ path: String, id: String) -> Data {
        TranscriptFixture.toolUse("Read", id: id, input: ["file_path": path])
    }

    /// The paths a scan of `transcript` asked the floor about, in order, with the closure given run as each is asked.
    private func askedPaths(scanning transcript: URL, in directory: URL, snapshot: TranscriptSnapshot? = nil, onAsk: @escaping @Sendable (String) -> Void) -> [String] {
        let snapshot = snapshot ?? TranscriptSnapshot.take(projectsDirectory: directory, since: nil, transcript: transcript.path)
        let asked = OSAllocatedUnfairLock(initialState: [String]())
        let options = TranscriptAudit.ScanOptions(
            since: nil,
            until: nil,
            belowFloor: { path in
                asked.withLock { $0.append(path) }
                onAsk(path)
                return false
            },
            couldAnswer: { _, _ in true },
            memberExists: { _, _, _ in true },
            timeZone: .current,
            datesEveryLookup: false
        )
        _ = TranscriptAudit.scan(transcript, label: "fixture", session: "fixture", isSubagent: false, options: options, snapshot: snapshot)
        return asked.withLock(\.self)
    }

    /// Overwrites the last `old` in the file at `url` with `new`, a string of the same length, in place.
    private func rewriteLast(_ old: String, as new: String, in url: URL) {
        guard let data = try? Data(contentsOf: url), let range = data.range(of: Data(old.utf8), options: .backwards),
              let handle = try? FileHandle(forWritingTo: url)
        else { return }
        try? handle.seek(toOffset: UInt64(range.lowerBound))
        try? handle.write(contentsOf: Data(new.utf8))
        try? handle.close()
    }
}

/// The body of the pool test, run in a child process of its own so that nothing else allocates while it counts the process's heap.
private extension TranscriptStreamingTests {
    struct PoolScenario {
        static func perform(sourceLocation: SourceLocation = #_sourceLocation) throws {
            try TemporaryDirectory.withScope {
                let directory = try TemporaryDirectory.make("streaming")
                let transcript = directory.appendingPathComponent("session.jsonl")
                // Opening lines with no working directory, long enough that each probe reads megabytes before it gives up.
                let filler = Data(#"{"type":"queue-operation","content":"\#(String(repeating: "x", count: 100_000))"}"#.utf8)
                try Data(Array(repeating: filler, count: 25).joined(separator: Data([0x0A]))).write(to: transcript)

                var heldByThePool = 0
                autoreleasepool {
                    for _ in 0 ..< 40 {
                        #expect(TranscriptWorkingDirectory.of(transcriptAt: transcript) == nil, sourceLocation: sourceLocation)
                    }
                    heldByThePool = bytesInUse()
                }
                heldByThePool -= bytesInUse()

                // Left to the pool, forty probes of two megabytes each hold about a hundred.
                #expect(heldByThePool < 25_000_000, "draining the caller's pool after the probes freed \(heldByThePool) bytes", sourceLocation: sourceLocation)
            }
        }

        /// The bytes every malloc zone of the process has handed out and not had back.
        private static func bytesInUse() -> Int {
            var statistics = malloc_statistics_t()
            malloc_zone_statistics(nil, &statistics)
            return statistics.size_in_use
        }
    }
}
