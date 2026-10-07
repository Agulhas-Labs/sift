//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// Covers `sift audit --until`: the header it names, and the empty window it refuses — kept apart from `TranscriptAuditTests` so that file stays inside the length the project holds every file to.
@Suite(.temporaryDirectories)
struct TranscriptAuditUntilTests {
    private static func toolUse(_ name: String, id: String = "t1", input: [String: Any] = [:]) -> String {
        let object: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Builds a `projects/<project>/<session>.jsonl` tree.
    private static func projects(session: [String], project: String = "-Users-someone-Developer-App") throws -> URL {
        let root = try TemporaryDirectory.make("audit-until").appendingPathComponent("audit")
        let directory = root.appendingPathComponent(project)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcript = directory.appendingPathComponent("11112222-3333.jsonl")
        try (session.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        return root
    }

    /// A window holding a single day names that day alone — `until` is exclusive, so pairing `since` with `until`'s own day would read as two days when the window holds only one.
    @Test
    func theHeaderNamesTheSingleDayAWindowOfOneDayHolds() throws {
        let root = try Self.projects(session: [
            Self.toolUse("Read", id: "a", input: ["file_path": "/repo/A.swift"]),
        ])
        let since = try #require(ISO8601DateFormatter().date(from: "2026-09-23T00:00:00Z"))
        let until = try #require(ISO8601DateFormatter().date(from: "2026-09-24T00:00:00Z"))

        let report = TranscriptAudit.render(projectsDirectory: root, since: since, until: until, timeZone: .gmt)

        #expect(report.contains("2026-09-23"), "\(report)")
        #expect(!report.contains("2026-09-23 → 2026-09-24"), "\(report)")
    }

    /// A window spanning more than one day names the last day it actually includes, not `until` itself.
    @Test
    func theHeaderNamesTheLastDayIncludedWhenTheWindowSpansSeveralDays() throws {
        let root = try Self.projects(session: [
            Self.toolUse("Read", id: "a", input: ["file_path": "/repo/A.swift"]),
        ])
        let since = try #require(ISO8601DateFormatter().date(from: "2026-09-22T00:00:00Z"))
        let until = try #require(ISO8601DateFormatter().date(from: "2026-09-24T00:00:00Z"))

        let report = TranscriptAudit.render(projectsDirectory: root, since: since, until: until, timeZone: .gmt)

        #expect(report.contains("2026-09-22 → 2026-09-23"), "\(report)")
    }

    /// `--until` before `--since` would report on an empty window, so `audit` refuses it up front rather than printing "nothing to audit" as if the window had simply missed everything.
    @Test
    func anUntilBeforeSinceIsRefused() throws {
        let command = try AuditCommand.parse(["--since", "2026-09-24", "--until", "2026-09-23"])

        do {
            try command.run()
            Issue.record("expected a refusal")
        } catch let error as ValidationError {
            #expect(error.message == "--until 2026-09-23 is not after --since 2026-09-24: the window would be empty.")
        }
    }

    /// `--until` equal to `--since` is the same empty window — the boundary the `<` in the check above would miss.
    @Test
    func anUntilEqualToSinceIsRefused() throws {
        let command = try AuditCommand.parse(["--since", "2026-09-23", "--until", "2026-09-23"])

        do {
            try command.run()
            Issue.record("expected a refusal")
        } catch let error as ValidationError {
            #expect(error.message == "--until 2026-09-23 is not after --since 2026-09-23: the window would be empty.")
        }
    }

    /// `--transcript` audits one transcript regardless of age, so `--since` and `--until` alongside it are silently dropped — a note on stderr says so instead of leaving the omission to be discovered.
    @Test
    func sinceAndUntilAreNotedAsIgnoredWithTranscript() throws {
        let root = try Self.projects(session: [
            Self.toolUse("Read", id: "a", input: ["file_path": "/repo/A.swift"]),
        ])
        let transcriptPath = root
            .appendingPathComponent("-Users-someone-Developer-App")
            .appendingPathComponent("11112222-3333.jsonl").path
        var command = try AuditCommand.parse(["--since", "3d", "--until", "1d", "--transcript", transcriptPath])
        let recorded = RecordedOutput()
        command.output = recorded.output

        try command.run()

        #expect(recorded.errors == [
            "audit: --since and --until ignored with --transcript, which audits that one transcript regardless of age.",
        ])
    }

    /// A lone `--until` alongside `--transcript` is named on its own, not paired with a `--since` that was never given.
    @Test
    func untilAloneIsNotedAsIgnoredWithTranscript() throws {
        let root = try Self.projects(session: [
            Self.toolUse("Read", id: "a", input: ["file_path": "/repo/A.swift"]),
        ])
        let transcriptPath = root
            .appendingPathComponent("-Users-someone-Developer-App")
            .appendingPathComponent("11112222-3333.jsonl").path
        var command = try AuditCommand.parse(["--until", "1d", "--transcript", transcriptPath])
        let recorded = RecordedOutput()
        command.output = recorded.output

        try command.run()

        #expect(recorded.errors == [
            "audit: --until ignored with --transcript, which audits that one transcript regardless of age.",
        ])
    }

    /// `--root` doesn't yet reach the replay section or `--shapes`, so pairing either with it would print a scoped audit followed by a replay of every repository — refused up front rather than left to surprise.
    @Test
    func rootWithReplayIsRefused() throws {
        #expect(throws: (any Error).self) {
            try AuditCommand.parse(["--root", "/repo", "--replay"])
        }
    }

    /// `--shapes` needs `--replay` too, so a bare `--root --shapes` still names the replay it can't yet scope.
    @Test
    func rootWithShapesIsRefused() throws {
        #expect(throws: (any Error).self) {
            try AuditCommand.parse(["--root", "/repo", "--replay", "--shapes", "/tmp/shapes.txt"])
        }
    }

    /// An unmatched `--root` lists the registered roots as fragments, not raw absolute paths, unless `--unredact` says otherwise — the refusal must not hand back this machine's layout and username.
    @Test
    func anUnmatchedRootListsFragmentsUnlessUnredacted() throws {
        let redacted = try #require(throws: ValidationError.self) {
            _ = try AuditCommand.scopedRoot("Missing", knownRoots: ["/Users/someone/Developer/App"], unredact: false)
        }
        #expect(!redacted.message.contains("/Users/someone/Developer/App"), "\(redacted.message)")
        #expect(redacted.message.contains("App"), "\(redacted.message)")

        let unredacted = try #require(throws: ValidationError.self) {
            _ = try AuditCommand.scopedRoot("Missing", knownRoots: ["/Users/someone/Developer/App"], unredact: true)
        }
        #expect(unredacted.message.contains("/Users/someone/Developer/App"), "\(unredacted.message)")
    }

    /// The same holds for an ambiguous `--root`, which lists more than one candidate.
    @Test
    func anAmbiguousRootListsFragmentsUnlessUnredacted() throws {
        let roots = ["/Users/someone/Developer/One/app", "/Users/someone/Developer/Two/app"]
        let redacted = try #require(throws: ValidationError.self) {
            _ = try AuditCommand.scopedRoot("app", knownRoots: roots, unredact: false)
        }
        #expect(!redacted.message.contains("/Users/someone"), "\(redacted.message)")

        let unredacted = try #require(throws: ValidationError.self) {
            _ = try AuditCommand.scopedRoot("app", knownRoots: roots, unredact: true)
        }
        #expect(unredacted.message.contains("/Users/someone/Developer/One/app"), "\(unredacted.message)")
    }
}
