//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// `audit --scan-diff`'s listing cap, its `--all-windows` lift and its `--root` scope.
@Suite(.temporaryDirectories) struct ScanDiffListingTests {
    /// A group past the cap lists the first hundred and ends on a line saying how many of how many it listed, and `--all-windows` for the rest.
    @Test func aGroupPastTheCapSaysItListedOnlyTheFirstHundred() {
        let (theirs, ours) = Self.moved(count: 105)

        let lines = ScanDiff.lines(theirs: theirs, ours: ours, redactor: nil)

        #expect(ScanDiff.listedPerClass == 100)
        #expect(lines.count { $0.contains("  call r") } == 100)
        #expect(lines.contains("          … listed 100 of 105 — --all-windows for the rest"), "\(lines.suffix(3))")
        #expect(lines.last == "  scan differs on 105 of 105 windows — guided 0 → 105, cold 105 → 0 (its → this one's)")
    }

    /// A group of exactly the cap is listed whole, with no cut line.
    @Test func aGroupAtTheCapIsListedWhole() {
        let (theirs, ours) = Self.moved(count: 100)

        let lines = ScanDiff.lines(theirs: theirs, ours: ours, redactor: nil)

        #expect(lines.count { $0.contains("  call r") } == 100)
        #expect(!lines.contains { $0.contains("listed 100 of") }, "\(lines)")
    }

    /// Lifting the cap lists every window of the group and prints no cut line.
    @Test func listingAllWindowsListsEveryOne() {
        let (theirs, ours) = Self.moved(count: 105)

        let lines = ScanDiff.lines(theirs: theirs, ours: ours, listsAll: true, redactor: nil)

        #expect(lines.count { $0.contains("  call r") } == 105)
        #expect(!lines.contains { $0.contains("--all-windows for the rest") }, "\(lines)")
    }

    /// The unstable group is cut at the same cap, with the same line.
    @Test func theUnstableGroupIsCutAtTheCapToo() {
        let (theirs, ours) = Self.moved(count: 101)
        let flipped = theirs.map { ScoredWindow(session: $0.session, call: $0.call, classification: "guided", file: $0.file, locator: nil) }

        let lines = ScanDiff.lines(theirs: theirs, ours: ours, again: (theirs: flipped, ours: ours), redactor: nil)

        #expect(lines.contains("          … listed 100 of 101 — --all-windows for the rest"), "\(lines)")
        #expect(lines.last == "  scan differs on 0 of 101 windows — guided 0 → 101, cold 101 → 0 (its → this one's)")
    }

    /// `--all-windows` is refused without `--scan-diff`, naming it, and accepted with it.
    @Test func allWindowsNeedsScanDiff() throws {
        #expect(Self.refusal(of: ["--all-windows"])?.contains("--scan-diff") == true)

        _ = try AuditCommand.parse(["--scan-diff", "--against", "/bin/true", "--all-windows"])
        _ = try AuditCommand.parse(["--scan-diff", "--against", "/bin/true", "--root", "Orchard"])
        #expect(Self.refusal(of: ["--scan-diff", "--against", "/bin/true", "--replay"])?.contains("--replay") == true)
    }

    /// A scoped snapshot keeps the transcripts whose own recorded directory is under the root, and a subagent in the root under a session outside it with the session and call ids it has unscoped.
    @Test func aScopedSnapshotKeepsEachWindowsAttribution() throws {
        let directory = try TemporaryDirectory.make("projects").appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.write("inside", cwd: "/nowhere/orchard/app", calls: ["i1"], in: directory)
        _ = try Self.write("outside", cwd: "/nowhere/elsewhere", calls: ["o1"], in: directory)
        let agents = directory.appendingPathComponent("outside/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Self.write(named: "agent-a1", cwd: "/nowhere/orchard", calls: ["a1"], in: agents)
        try Self.write(named: "agent-a2", cwd: "/nowhere/elsewhere", calls: ["a2"], in: agents)
        let snapshot = TranscriptSnapshot.take(projectsDirectory: directory.deletingLastPathComponent(), since: nil, transcript: nil)
        defer { snapshot.indexes.close() }

        let all = ScanDumpRequest(snapshot: snapshot, since: nil, until: nil, suppressionLog: nil).windows()
        let scoped = snapshot.scoped(to: "/nowhere/orchard")
        let kept = ScanDumpRequest(snapshot: scoped, since: nil, until: nil, suppressionLog: nil).windows()

        #expect(Set(all.map(\.key)) == ["inside i1 lookup", "outside o1 lookup", "outside a1 lookup", "outside a2 lookup"], "\(all)")
        #expect(Set(kept.map(\.key)) == ["inside i1 lookup", "outside a1 lookup"], "\(kept)")
        #expect(scoped.sessions.map(\.lastPathComponent).sorted() == ["agent-a1.jsonl", "inside.jsonl"])
    }

    /// What parsing `arguments` is refused with, `nil` where it parses.
    private static func refusal(of arguments: [String]) -> String? {
        do {
            _ = try AuditCommand.parse(arguments)
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// `count` windows each scan scores cold in the other build and guided in this one, in one session.
    private static func moved(count: Int) -> (theirs: [ScoredWindow], ours: [ScoredWindow]) {
        let ours = (1 ... count).map { ScoredWindow(session: "capped", call: String(format: "r%03d", $0), classification: "guided", file: "/nowhere/Depot.swift", locator: nil) }
        let theirs = ours.map { ScoredWindow(session: $0.session, call: $0.call, classification: "cold", file: $0.file, locator: nil) }
        return (theirs, ours)
    }

    /// A transcript named `name` in `directory`, each of `calls` a ranged read recorded in `cwd`.
    @discardableResult
    private static func write(_ name: String, cwd: String, calls: [String], in directory: URL) throws -> URL {
        try write(named: name, cwd: cwd, calls: calls, in: directory)
    }

    @discardableResult
    private static func write(named name: String, cwd: String, calls: [String], in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(name).jsonl")
        let lines = calls.flatMap { call in
            [
                TranscriptFixture.toolUse("Read", id: call, input: ["file_path": "/nowhere/Sources/\(call).swift", "offset": 10, "limit": 20], cwd: cwd),
                TranscriptFixture.toolResult(id: call, isError: false, text: "struct Depot"),
            ]
        }
        try Data(lines.joined(separator: [0x0A])).write(to: url)
        return url
    }
}
