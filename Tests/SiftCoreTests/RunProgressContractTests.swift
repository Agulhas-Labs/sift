//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Holds the progress snapshot to `Docs/ProgressContract.md`: the keys it encodes are the schema's, every one always present, and the documented example reads back.
@Suite(.temporaryDirectories)
struct RunProgressContractTests {
    private static let contract = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Docs/ProgressContract.md")

    /// The first fenced JSON block after `heading`, parsed.
    private static func block(after heading: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> Any {
        let text = try String(contentsOf: contract, encoding: .utf8)
        let section = try #require(text.range(of: "\n\(heading)\n"), sourceLocation: sourceLocation)
        let rest = text[section.upperBound...]
        let open = try #require(rest.range(of: "```json\n"), sourceLocation: sourceLocation)
        let close = try #require(rest[open.upperBound...].range(of: "\n```"), sourceLocation: sourceLocation)
        return try JSONSerialization.jsonObject(with: Data(rest[open.upperBound ..< close.lowerBound].utf8))
    }

    private static func object(_ value: Any?, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        try #require(value as? [String: Any], sourceLocation: sourceLocation)
    }

    private static let started = Date(timeIntervalSince1970: 1_790_000_000)

    /// A snapshot with nothing known yet: every optional nil.
    private static let bare = RunProgressSnapshot(runId: "run-1", pid: 4242, repoRoot: "/tmp/repo", startedAt: started, command: "swift build")

    /// A snapshot with every optional set, an ended run's.
    private static var full: RunProgressSnapshot {
        var snapshot = RunProgressSnapshot(
            runId: "run-2",
            pid: 4243,
            repoRoot: "/tmp/repo",
            startedAt: started,
            command: "xcodebuild test -scheme App",
            scheme: "App",
            destination: "platform=iOS Simulator,name=iPhone 17",
            logPath: "/tmp/repo/.sift/runs/run-1.log"
        )
        snapshot.phase = .failed
        snapshot.updatedAt = started + 95
        snapshot.phaseStartedAt = started + 95
        snapshot.current = "AppTests/aTestThatFailed()"
        snapshot.tests = RunProgressSnapshot.TestCounts(planned: 300, passed: 298, failed: 2, skipped: 0)
        snapshot.errors = 1
        snapshot.warnings = 4
        snapshot.summary = RunProgressSnapshot.Timings(buildMs: 40000, testMs: 55000, totalMs: 95000)
        snapshot.exitCode = 65
        return snapshot
    }

    private static func encodedObject(_ snapshot: RunProgressSnapshot) throws -> [String: Any] {
        try object(JSONSerialization.jsonObject(with: snapshot.encoded()))
    }

    /// A snapshot reads back equal to itself, with nothing known and with everything known.
    @Test(arguments: [bare, full])
    func roundTrips(snapshot: RunProgressSnapshot) throws {
        #expect(try RunProgressSnapshot.decoded(from: snapshot.encoded()) == snapshot)
    }

    /// Timestamps are UTC with milliseconds, and keys are written sorted.
    @Test
    func encodesTheContractsTimestampsInSortedOrder() throws {
        var snapshot = Self.bare
        snapshot.updatedAt = Self.started + 1.5
        let text = try #require(String(bytes: snapshot.encoded(), encoding: .utf8))

        #expect(text.contains(#""startedAt":"2026-09-21T14:13:20.000Z""#))
        #expect(text.contains(#""updatedAt":"2026-09-21T14:13:21.500Z""#))
        #expect(text.hasPrefix(#"{"command":"#))
    }

    /// The encoded keys are exactly the schema's properties and exactly its required list, at the top and in both nested objects, whether the optionals are nil or set; the phase enum and the version constant agree; no level admits another key.
    @Test(arguments: [bare, full])
    func encodedKeysMatchTheDocumentedSchema(snapshot: RunProgressSnapshot) throws {
        let schema = try Self.object(Self.block(after: "## 2. The schema"))
        let encoded = try Self.encodedObject(snapshot)
        try Self.expectKeys(Set(encoded.keys), match: schema)

        let properties = try Self.object(schema["properties"])
        let tests = try Self.object(properties["tests"])
        try Self.expectKeys(Set(Self.object(encoded["tests"]).keys), match: tests)
        let summary = try Self.object(properties["summary"])
        if let timings = encoded["summary"] as? [String: Any] {
            try Self.expectKeys(Set(timings.keys), match: summary)
        } else {
            #expect(encoded["summary"] is NSNull)
            try Self.expectKeys(["buildMs", "testMs", "totalMs"], match: summary)
        }

        let phases = try #require(Self.object(properties["phase"])["enum"] as? [String])

        #expect(Set(phases) == Set(RunProgressSnapshot.Phase.allCases.map(\.rawValue)))
        #expect(try Self.object(properties["schemaVersion"])["const"] as? Int == RunProgressSnapshot.currentSchemaVersion)
        #expect(try Self.object(properties["command"])["maxLength"] as? Int == RunProgressSnapshot.commandLimit)
    }

    private static func expectKeys(_ keys: Set<String>, match schema: [String: Any], sourceLocation: SourceLocation = #_sourceLocation) throws {
        let properties = try Set(object(schema["properties"], sourceLocation: sourceLocation).keys)
        let required = try Set(#require(schema["required"] as? [String], sourceLocation: sourceLocation))

        #expect(keys == properties, sourceLocation: sourceLocation)
        #expect(keys == required, sourceLocation: sourceLocation)
        #expect(schema["additionalProperties"] as? Bool == false, sourceLocation: sourceLocation)
    }

    /// The documented example is a snapshot this type reads, and re-encodes to the same keys and values.
    @Test
    func theDocumentedExampleReadsBack() throws {
        let example = try Self.block(after: "## 3. An example")
        let data = try JSONSerialization.data(withJSONObject: example)
        let snapshot = try RunProgressSnapshot.decoded(from: data)

        #expect(snapshot.phase == .testing)
        #expect(try NSDictionary(dictionary: Self.encodedObject(snapshot)) == NSDictionary(dictionary: Self.object(example)))
    }

    /// The file sits in the repository's cache directory, or under the directory a scoped run writes to.
    @Test
    func thePathFollowsTheWritesUnderSeam() throws {
        let repository = try TemporaryDirectory.make("run-progress-repo")
        let scoped = try TemporaryDirectory.make("run-progress-scope")

        #expect(RunProgressPaths.directory(in: repository, writesUnder: nil) == repository.appendingPathComponent(".sift/progress", isDirectory: true))
        #expect(RunProgressPaths.directory(in: repository, writesUnder: scoped) == scoped.appendingPathComponent(".sift/progress", isDirectory: true))
        #expect(RunProgressPaths.file(runId: "abc", in: scoped).lastPathComponent == "run-abc.json")
    }
}
