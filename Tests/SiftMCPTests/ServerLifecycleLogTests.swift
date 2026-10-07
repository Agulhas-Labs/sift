//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Covers the record a dropped server leaves behind — without which a drop leaves no account of itself anywhere.
@Suite(.temporaryDirectories)
struct ServerLifecycleLogTests {
    private static func temporaryLog() throws -> URL {
        let directory = try TemporaryDirectory.make("lifecycle")
        return directory.appendingPathComponent("server.jsonl")
    }

    private static func entries(_ fileURL: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
        }
    }

    @Test
    func aServerRecordsItsStartAndTheReasonItStopped() throws {
        let fileURL = try Self.temporaryLog()
        let log = ServerLifecycleLog(fileURL: fileURL)
        let started = Date(timeIntervalSince1970: 1_000_000)

        log.recordStart(pid: 4321, session: "abc", root: "/tmp/repo", now: started)
        log.recordStop(pid: 4321, reason: .inputClosed, startedAt: started, now: started.addingTimeInterval(90))
        let written = Self.entries(fileURL)

        #expect(written.count == 2)
        #expect(written.first?["event"] as? String == "start")
        #expect(written.first?["pid"] as? Int == 4321)
        #expect(written.first?["session"] as? String == "abc")
        #expect(written.last?["event"] as? String == "stop")
        #expect(written.last?["reason"] as? String == "input-closed")
        #expect(written.last?["seconds"] as? Int == 90)
    }

    /// A server that took a replaced binary over records it as one process carrying on — a re-exec, with how long it had been up and the version it runs now — not as a stop and a start.
    @Test
    func aServerThatReplacedItsImageRecordsAReexec() throws {
        let fileURL = try Self.temporaryLog()
        let log = ServerLifecycleLog(fileURL: fileURL)
        let started = Date(timeIntervalSince1970: 1_000_000)

        log.recordStart(pid: 4321, session: "abc", root: "/tmp/repo", now: started)
        log.recordReexec(pid: 4321, startedAt: started, now: started.addingTimeInterval(600))
        let written = Self.entries(fileURL)

        #expect(written.map { $0["event"] as? String } == ["start", "reexec"])
        #expect(written.last?["pid"] as? Int == 4321)
        #expect(written.last?["seconds"] as? Int == 600)
        #expect(written.last?["version"] as? String == SiftVersion.current)
    }

    /// A start line names the process the server will end with, and reads back with it; one that never recorded a parent reads back without one.
    @Test
    func aStartNamesTheParentItWatches() throws {
        let fileURL = try Self.temporaryLog()
        let log = ServerLifecycleLog(fileURL: fileURL)

        log.recordStart(pid: 4321, session: nil, root: "/tmp/repo", parent: 1234)
        log.recordStart(pid: 4322, session: nil, root: "/tmp/repo")
        let starts = ServerLifecycleReport.entries(in: fileURL)

        #expect(starts.map(\.parent) == [1234, nil])
    }

    /// The case that is actually worth having: a signal names itself, so `pkill` reads as `pkill` and not as a session that mysteriously ended.
    @Test
    func aSignalledStopNamesTheSignal() throws {
        let fileURL = try Self.temporaryLog()
        let log = ServerLifecycleLog(fileURL: fileURL)

        log.recordStop(pid: 7, reason: .signalled(number: SIGTERM), startedAt: Date())
        let written = try #require(Self.entries(fileURL).last)

        #expect(written["reason"] as? String == "signalled")
        #expect(written["detail"] as? String == "SIGTERM")
    }

    /// A read failure carries the `errno` in words, since a bare number is a thing to go and look up.
    @Test
    func aFailedReadRecordsWhatTheSystemSaid() throws {
        let fileURL = try Self.temporaryLog()
        let log = ServerLifecycleLog(fileURL: fileURL)

        log.recordStop(pid: 7, reason: .inputFailed(code: EIO), startedAt: Date())
        let detail = try #require(Self.entries(fileURL).last?["detail"] as? String)

        #expect(detail.contains("errno \(EIO)"))
        #expect(detail.lowercased().contains("input/output error"))
    }

    /// A long-lived process may not grow a file without limit, which is the whole reason this is a cap and not a plain append.
    @Test
    func theLogIsBounded() throws {
        let fileURL = try Self.temporaryLog()
        let log = ServerLifecycleLog(fileURL: fileURL)
        for pid in 1 ... (ServerLifecycleLog.entryCap + 5) {
            log.recordStart(pid: Int32(pid), session: nil, root: "/tmp/repo")
        }

        let written = Self.entries(fileURL)

        #expect(written.count <= ServerLifecycleLog.entryCap)
        // The trim keeps the newest, which is the end a diagnosis is read from.
        #expect(written.last?["pid"] as? Int == ServerLifecycleLog.entryCap + 5)
    }

    /// A trim keeps the start line of a server still running, however old the line, since the hook finds the server answering its caller by it; it keeps the newest such line per pid and drops one whose process has gone.
    @Test
    func aTrimKeepsTheStartLineOfAServerStillRunning() throws {
        let fileURL = try Self.temporaryLog()
        let log = ServerLifecycleLog(fileURL: fileURL)
        let launched = ServerLifecycleReport.startTime(of: getpid()) ?? Date()
        log.recordStart(pid: getpid(), session: "long-session", root: "/tmp/live-first", parent: getppid(), now: launched)
        log.recordStart(pid: getpid(), session: "long-session", root: "/tmp/live", parent: getppid(), now: launched)
        try log.recordStart(pid: ServerRootByParentTests.exitedPid(), session: "long-session", root: "/tmp/gone", parent: getppid())
        let longAgo = Date(timeIntervalSince1970: 1_000_000)
        for offset in 1 ... ServerLifecycleLog.entryCap {
            log.recordStart(pid: Int32(100_000 + offset), session: nil, root: "/tmp/filler", now: longAgo)
        }

        let written = Self.entries(fileURL)
        let roots = written.compactMap { $0["root"] as? String }

        #expect(written.count <= ServerLifecycleLog.entryCap)
        #expect(roots.first == "/tmp/live")
        #expect(!roots.contains("/tmp/live-first"))
        #expect(!roots.contains("/tmp/gone"))
    }
}
