//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// `audit --scan-diff` and the `scan-dump` entry point it drives: every window two builds' scans class differently over one snapshot, with the call that located each window's file under each.
@Suite(.temporaryDirectories) struct ScanDiffTests {
    /// The digest is dumped as its own `indexed` window, a ranged read of the file it located is dumped guided, naming that digest, and one of a file nothing located is dumped cold with a `null` locator — each line JSON that parses and decodes back to the window.
    @Test func theDumpNamesEachWindowsClassAndTheCallThatLocatedIt() throws {
        let windows = try Self.windows(of: Self.transcript())

        try #require(windows.count == 3, "\(windows)")
        #expect(windows.map(\.classification) == ["indexed", "guided", "cold"])
        #expect(windows.map(\.call) == ["d1", "r1", "r2"])
        #expect(windows.map(\.part) == ["index", "lookup", "lookup"])
        #expect(windows.allSatisfy { $0.session == "scanned-session" })
        #expect(windows[1].file == "/nowhere/Sources/Depot.swift")
        #expect(windows[1].locator == LocatingCall(tool: "digest", call: "d1"))
        #expect(windows[2].locator == nil)
        for window in windows {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(window.jsonLine.utf8)) as? [String: Any])
            #expect(object.keys.sorted() == ["call", "classification", "file", "locator", "part", "session"])
            #expect(try JSONDecoder().decode(ScoredWindow.self, from: Data(window.jsonLine.utf8)) == window)
        }
        #expect(windows[2].jsonLine.contains(#""locator":null"#))
    }

    /// A line from a dump written before `part` decodes as the call's held window, one without `file` or `locator` as having none, and one without `classification` fails.
    @Test func anOlderDumpsLineDecodesWhereItCanAndFailsWhereItCannot() throws {
        let older = try JSONDecoder().decode(ScoredWindow.self, from: Data(#"{"session":"s","call":"r1","classification":"cold"}"#.utf8))

        #expect(older == ScoredWindow(session: "s", call: "r1", part: "lookup", classification: "cold", file: nil, locator: nil))
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ScoredWindow.self, from: Data(#"{"session":"s","call":"r1"}"#.utf8)) }
    }

    /// Every lookup the audit counts is dumped: an MCP index call as `indexed`, a Bash `sift` query as `indexed(cli)`, each under its own call's `index` part, and an index call that came back an error as `retracted` — so the windows still counted are exactly the audit's Swift lookups.
    @Test func everyLookupTheAuditCountsIsDumpedWithItsRoute() throws {
        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("routed-session.jsonl")
        let lines = TranscriptFixture.answeredDigest("Depot", id: "d1", file: "Sources/Depot.swift") + [
            TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sift where Crate"]),
            TranscriptFixture.toolResult(id: "b1", isError: false, text: "Crate.swift:3"),
            TranscriptFixture.toolUse("mcp__sift__digest", id: "f1", input: ["target": "Ledger"]),
            TranscriptFixture.toolResult(id: "f1", isError: true, text: "digest failed: the index is corrupt"),
            TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/nowhere/Sources/Depot.swift", "offset": 10, "limit": 20]),
            TranscriptFixture.toolResult(id: "r1", isError: false, text: "struct Depot"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let windows = try Self.windows(of: transcript)
        let audit = TranscriptAudit.render(projectsDirectory: transcript.deletingLastPathComponent(), transcript: transcript.path)

        #expect(windows.map { "\($0.call) \($0.part) \($0.classification)" } == ["d1 index indexed", "b1 index indexed(cli)", "f1 index retracted", "r1 lookup guided"])
        #expect(audit.contains(", 3 Swift lookups"), "\(audit)")
        #expect(windows.count { $0.classification != "retracted" } == 3)
    }

    /// An index call the other build's dump holds no window for is listed as `absent → indexed` under its call's `index` part, rather than lost from both sides.
    @Test func anIndexCallTheOtherBuildLeftUncountedIsListedAbsent() throws {
        let transcript = try Self.transcript()
        let read = ScoredWindow(session: "scanned-session", call: "r1", classification: "guided", file: "/nowhere/Sources/Depot.swift", locator: LocatingCall(tool: "digest", call: "d1"))
        let other = ScoredWindow(session: "scanned-session", call: "r2", classification: "cold", file: "/nowhere/Sources/Crate.swift", locator: nil)
        let stub = try Self.script("""
        input=$(cat)
        case "$input" in *'"sessions":[]'*) exit 0 ;; esac
        echo '\(read.jsonLine)'
        echo '\(other.jsonLine)'
        """)
        let recorded = RecordedOutput()
        var command = try AuditCommand.parse(["--transcript", transcript.path, "--against", stub.path, "--scan-diff", "--unredact"])
        command.output = recorded.output

        try command.run()

        let lines = recorded.printed.components(separatedBy: "\n")
        let group = try #require(lines.firstIndex { $0 == "         1  absent → indexed" }, "\(lines)")

        #expect(lines[group + 1] == "          (no file)  session scanned-session  call d1 (index)  located by none → none", "\(lines)")
        #expect(lines.contains("  scan differs on 1 of 3 windows — guided 1 → 1, cold 1 → 1 (its → this one's)"), "\(lines)")
    }

    /// A context whose one lookup the hook let run on worth is a Swift lookup to the audit as it is to the dump: the audit had dropped such a context, counting no withheld lookup as one made, and the two disagreed by that window.
    @Test func aContextWhoseOnlyLookupWasWithheldOnWorthIsCountedByBoth() throws {
        let directory = try TemporaryDirectory.make("projects")
        let transcript = directory.appendingPathComponent("withheld-session.jsonl")
        try TranscriptFixture.toolUse("Read", id: "w1", input: ["file_path": "/nowhere/Sources/Depot.swift", "offset": 10, "limit": 20]).write(to: transcript)
        let log = try TemporaryDirectory.make("log").appendingPathComponent("suppressions.jsonl")
        SuppressionLog(fileURL: log).note(symbol: "notSmaller", directory: "/nowhere", rule: "answerWithheld", call: "w1")
        let snapshot = TranscriptSnapshot.take(projectsDirectory: directory, since: nil, transcript: transcript.path)

        let windows = ScanDumpRequest(snapshot: snapshot, since: nil, until: nil, suppressionLog: log).windows()
        let audit = TranscriptAudit.render(projectsDirectory: directory, transcript: transcript.path, suppressionLog: log)

        #expect(windows.map(\.classification) == ["withheldOnWorth(notSmaller)"])
        #expect(audit.contains(", 1 Swift lookup"), "\(audit)")
    }

    /// The suppression log is read as it stood when the request was made: an entry written after it, while either scan runs, rescores no window on one side alone.
    @Test func theSuppressionLogIsReadOnlyAsFarAsTheRequestSawIt() throws {
        let directory = try TemporaryDirectory.make("projects")
        let transcript = directory.appendingPathComponent("logged-session.jsonl")
        let lines = [
            TranscriptFixture.toolUse("Read", id: "w1", input: ["file_path": "/nowhere/Sources/Depot.swift", "offset": 10, "limit": 20]),
            TranscriptFixture.toolUse("Read", id: "w2", input: ["file_path": "/nowhere/Sources/Crate.swift", "offset": 10, "limit": 20]),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)
        let log = try TemporaryDirectory.make("log").appendingPathComponent("suppressions.jsonl")
        SuppressionLog(fileURL: log).note(symbol: "notSmaller", directory: "/nowhere", rule: "answerWithheld", call: "w1")
        let snapshot = TranscriptSnapshot.take(projectsDirectory: directory, since: nil, transcript: transcript.path)
        let request = ScanDumpRequest(snapshot: snapshot, since: nil, until: nil, suppressionLog: log)
        SuppressionLog(fileURL: log).note(symbol: "notSmaller", directory: "/nowhere", rule: "answerWithheld", call: "w2")

        let windows = request.windows()

        #expect(windows.map { "\($0.call) \($0.classification)" } == ["w1 withheldOnWorth(notSmaller)", "w2 cold"])
    }

    /// A suppression log named but not there when the request is made is read by neither scan, so one the hook creates between the two rescores no window on one side alone.
    @Test func aSuppressionLogNotThereYetIsReadByNeitherScan() throws {
        let directory = try TemporaryDirectory.make("projects")
        let transcript = directory.appendingPathComponent("unlogged-session.jsonl")
        let line = TranscriptFixture.toolUse("Read", id: "w1", input: ["file_path": "/nowhere/Sources/Depot.swift", "offset": 10, "limit": 20])
        try line.write(to: transcript)
        let log = try TemporaryDirectory.make("log").appendingPathComponent("suppressions.jsonl")
        let snapshot = TranscriptSnapshot.take(projectsDirectory: directory, since: nil, transcript: transcript.path)
        let request = ScanDumpRequest(snapshot: snapshot, since: nil, until: nil, suppressionLog: log)
        SuppressionLog(fileURL: log).note(symbol: "notSmaller", directory: "/nowhere", rule: "answerWithheld", call: "w1")

        let windows = request.windows()

        #expect(windows.map { "\($0.call) \($0.classification)" } == ["w1 cold"])
    }

    /// A group of twelve windows is listed whole under the default cap, with nothing summed.
    @Test func aGroupUnderTheCapListsEveryWindow() {
        let ours = (1 ... 12).map { ScoredWindow(session: "capped", call: String(format: "r%02d", $0), classification: "guided", file: "/nowhere/Depot.swift", locator: nil) }
        let theirs = ours.map { ScoredWindow(session: $0.session, call: $0.call, classification: "cold", file: $0.file, locator: nil) }

        let lines = ScanDiff.lines(theirs: theirs, ours: ours, redactor: nil)

        #expect(lines.contains("        12  cold → guided"), "\(lines)")
        #expect(lines.count { $0.contains("  call r") } == 12)
        #expect(!lines.contains { $0.contains("more windows") || $0.contains("--all-windows") }, "\(lines)")
        #expect(lines.last == "  scan differs on 12 of 12 windows — guided 0 → 12, cold 12 → 0 (its → this one's)")
    }

    /// Two scans that class every window alike list nothing and total the windows with both scans' counts.
    @Test func identicalScansDifferOnNothing() throws {
        let windows = try Self.windows(of: Self.transcript())

        let lines = ScanDiff.lines(theirs: windows, ours: windows)

        #expect(lines.last == "  scan differs on 0 of 3 windows — guided 1 → 1, cold 1 → 1 (its → this one's)")
        #expect(!lines.contains { $0.contains(" → ") && $0.hasPrefix("      ") })
    }

    /// A window the other binary's dump classes cold, with nothing locating it, is listed under `cold → guided` with its file, session, call and both locators, through the other binary's own entry point.
    @Test func aWindowTheOtherBinaryClassesDifferentlyIsListedWithBothLocators() throws {
        let transcript = try Self.transcript()
        let other = ScoredWindow(session: "scanned-session", call: "r1", classification: "cold", file: "/nowhere/Sources/Depot.swift", locator: nil)
        let unchanged = ScoredWindow(session: "scanned-session", call: "r2", classification: "cold", file: "/nowhere/Sources/Crate.swift", locator: nil)
        let digest = ScoredWindow(session: "scanned-session", call: "d1", part: "index", classification: "indexed", file: nil, locator: nil)
        let stub = try Self.script("""
        input=$(cat)
        case "$input" in *'"sessions":[]'*) exit 0 ;; esac
        echo '\(digest.jsonLine)'
        echo '\(other.jsonLine)'
        echo '\(unchanged.jsonLine)'
        """)
        let recorded = RecordedOutput()
        var command = try AuditCommand.parse(["--transcript", transcript.path, "--against", stub.path, "--scan-diff", "--unredact"])
        command.output = recorded.output

        try command.run()

        let lines = recorded.printed.components(separatedBy: "\n")
        let group = try #require(lines.firstIndex { $0 == "         1  cold → guided" }, "\(lines)")

        #expect(lines[group + 1] == "          /nowhere/Sources/Depot.swift  session scanned-session  call r1  located by none → digest d1", "\(lines)")
        #expect(lines.contains("  scan differs on 1 of 3 windows — guided 0 → 1, cold 2 → 1 (its → this one's)"), "\(lines)")
    }

    /// A binary built before `--scan-diff` has no `scan-dump` entry point, and is refused in one line with nothing printed — though it answers `scan-dump --help` with its root help and a clean exit, as a real one does.
    @Test func aBinaryWithoutTheEntryPointIsRefusedInOneLine() throws {
        let transcript = try Self.transcript()
        let stub = try Self.script("""
        case " $* " in *" --help "*) echo "OVERVIEW: root help"; exit 0 ;; esac
        case "$1" in scan-dump) echo "Error: Unknown subcommand" >&2; exit 64 ;; esac
        exit 0
        """)
        let recorded = RecordedOutput()
        var command = try AuditCommand.parse(["--transcript", transcript.path, "--against", stub.path, "--scan-diff"])
        command.output = recorded.output

        #expect(throws: ExitCode.failure) { try command.run() }
        #expect(recorded.printed.isEmpty)
        #expect(recorded.errors == ["audit: --against \(stub.path) predates --scan-diff: it has no scan-dump entry point to score its windows with, so build it from a revision that has one."])
    }

    /// A session whose digest of `Depot` answers before a ranged read of it, and whose ranged read of `Crate` nothing located.
    private static func transcript() throws -> URL {
        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("scanned-session.jsonl")
        let lines = TranscriptFixture.answeredDigest("Depot", id: "d1", file: "Sources/Depot.swift") + [
            TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/nowhere/Sources/Depot.swift", "offset": 10, "limit": 20]),
            TranscriptFixture.toolResult(id: "r1", isError: false, text: "struct Depot"),
            TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": "/nowhere/Sources/Crate.swift", "offset": 10, "limit": 20]),
            TranscriptFixture.toolResult(id: "r2", isError: false, text: "struct Crate"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)
        return transcript
    }

    /// This build's dump of `transcript` alone, as `scan-dump` prints it.
    private static func windows(of transcript: URL) throws -> [ScoredWindow] {
        let snapshot = TranscriptSnapshot.take(projectsDirectory: transcript.deletingLastPathComponent(), since: nil, transcript: transcript.path)
        return ScanDumpRequest(snapshot: snapshot, since: nil, until: nil, suppressionLog: nil).windows()
    }

    private static func script(_ body: String) throws -> URL {
        let script = try TemporaryDirectory.make("stub").appendingPathComponent("sift")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}
