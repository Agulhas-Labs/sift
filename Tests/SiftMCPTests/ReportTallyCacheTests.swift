//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A second report over unchanged transcripts reads their counts from the tally cache, and states exactly what reading them again would.
@Suite(.temporaryDirectories) struct ReportTallyCacheTests {
    static var now: Date {
        ISO8601DateFormatter().date(from: "2026-08-16T12:00:00Z") ?? Date()
    }

    static var utc: TimeZone {
        TimeZone(identifier: "UTC") ?? .current
    }

    private static func toolUse(_ name: String, id: String, at timestamp: String, input: [String: Any]) -> String {
        let object: [String: Any] = [
            "type": "assistant",
            "timestamp": timestamp,
            "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    static func digest(_ id: String, at timestamp: String) -> String {
        toolUse("mcp__sift__digest", id: id, at: timestamp, input: ["target": "Widget"])
    }

    static func read(_ id: String, at timestamp: String, file: String = "BayGeometry") -> String {
        toolUse("Read", id: id, at: timestamp, input: ["file_path": "/repo/\(file).swift"])
    }

    static func fixture() throws -> Fixture {
        let directory = try TemporaryDirectory.make("report-tally-cache")
        let project = directory.appendingPathComponent("projects/-Users-someone-Developer-App", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("usage.jsonl")
        try Data().write(to: log)
        let cache = TranscriptTallyCache(fileURL: directory.appendingPathComponent("tallies.json"), build: "test-build")
        return Fixture(directory: directory, project: project, log: log, cache: cache)
    }

    /// Writes `lines` as a transcript and pins its modification date, so a rewrite can keep or move it on purpose.
    @discardableResult
    static func write(_ lines: [String], to url: URL, modified: Date) throws -> URL {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    static func report(_ fixture: Fixture, since: String = "7d", cached: Bool = true) -> ReportData {
        ReportData.assemble(
            logURL: fixture.log,
            projectsDirectory: fixture.directory.appendingPathComponent("projects"),
            roots: [],
            since: since,
            root: nil,
            now: now,
            timeZone: utc,
            tallyCache: cached ? fixture.cache : nil,
            moduleHealth: { _ in nil }
        )
    }

    static var written: Date {
        ISO8601DateFormatter().date(from: "2026-08-15T12:00:00Z") ?? Date()
    }

    /// The cached run, the run that fills the cache and a run with no cache state the same page.
    @Test
    func aCachedReportIsTheUncachedReport() throws {
        let fixture = try Self.fixture()
        try Self.write([Self.digest("a", at: "2026-08-11T12:00:00Z"), Self.read("b", at: "2026-08-12T12:00:00Z")], to: fixture.project.appendingPathComponent("one.jsonl"), modified: Self.written)
        try Self.write([Self.read("c", at: "2026-08-13T12:00:00Z")], to: fixture.project.appendingPathComponent("two.jsonl"), modified: Self.written)

        let uncached = Self.report(fixture, cached: false)
        let filling = Self.report(fixture)
        let cached = Self.report(fixture)

        #expect(uncached.share?.tally.total == 3)
        #expect(filling == uncached)
        #expect(cached == uncached)
        #expect(ReportPage.render(cached) == ReportPage.render(uncached))
    }

    /// An unchanged transcript is not read again: rewritten behind the cache's back with its size and date kept, it still reports what the cache stored.
    @Test
    func anUnchangedTranscriptIsReadFromTheCache() throws {
        let fixture = try Self.fixture()
        let transcript = fixture.project.appendingPathComponent("one.jsonl")
        try Self.write([Self.digest("a", at: "2026-08-12T12:00:00Z")], to: transcript, modified: Self.written)
        let first = Self.report(fixture)

        try Self.write([Self.digest("b", at: "2026-08-13T12:00:00Z")], to: transcript, modified: Self.written)

        #expect(Self.report(fixture) == first)
        #expect(Self.report(fixture, cached: false) != first)
    }

    /// A transcript whose date moved is read again, even at the same size.
    @Test
    func aTranscriptWithANewDateIsReadAgain() throws {
        let fixture = try Self.fixture()
        let transcript = fixture.project.appendingPathComponent("one.jsonl")
        try Self.write([Self.digest("a", at: "2026-08-12T12:00:00Z")], to: transcript, modified: Self.written)
        _ = Self.report(fixture)

        try Self.write([Self.digest("b", at: "2026-08-13T12:00:00Z")], to: transcript, modified: Self.written + 60)

        #expect(Self.report(fixture).share?.byDay.map(\.day) == ["2026-08-13"])
    }

    /// A transcript that grew is read again, even with its old date put back.
    @Test
    func aTranscriptThatGrewIsReadAgain() throws {
        let fixture = try Self.fixture()
        let transcript = fixture.project.appendingPathComponent("one.jsonl")
        try Self.write([Self.digest("a", at: "2026-08-12T12:00:00Z")], to: transcript, modified: Self.written)
        _ = Self.report(fixture)

        try Self.write([Self.digest("a", at: "2026-08-12T12:00:00Z"), Self.read("b", at: "2026-08-13T12:00:00Z")], to: transcript, modified: Self.written)

        #expect(Self.report(fixture).share?.tally.total == 2)
    }

    /// A transcript that straddles the window's start is keyed by that start: a later window does not reuse the earlier one's count.
    @Test
    func aTranscriptStraddlingTheWindowIsKeyedByItsStart() throws {
        let fixture = try Self.fixture()
        try Self.write([Self.read("a", at: "2026-08-08T12:00:00Z", file: "DepotCatalog"), Self.read("b", at: "2026-08-12T12:00:00Z")], to: fixture.project.appendingPathComponent("one.jsonl"), modified: Self.written)

        let week = Self.report(fixture, since: "7d")
        let fortnight = Self.report(fixture, since: "14d")

        #expect(week.share?.tally.total == 1)
        #expect(fortnight.share?.tally.total == 2)
        #expect(fortnight == Self.report(fixture, since: "14d", cached: false))
        #expect(Self.report(fixture, since: "7d") == week)
    }

    /// A transcript wholly inside two windows is read once: the second window reuses the first one's count.
    @Test
    func aTranscriptInsideBothWindowsIsReadOnce() throws {
        let fixture = try Self.fixture()
        let transcript = fixture.project.appendingPathComponent("one.jsonl")
        try Self.write([Self.digest("a", at: "2026-08-12T12:00:00Z")], to: transcript, modified: Self.written)
        let week = Self.report(fixture, since: "7d")

        try Self.write([Self.digest("b", at: "2026-08-13T12:00:00Z")], to: transcript, modified: Self.written)

        #expect(Self.report(fixture, since: "14d").share?.byDay == week.share?.byDay)
    }

    /// A deleted transcript leaves the cache file the next time it is written.
    @Test
    func aDeletedTranscriptDropsOutOfTheCache() throws {
        let fixture = try Self.fixture()
        let kept = try Self.write([Self.digest("a", at: "2026-08-12T12:00:00Z")], to: fixture.project.appendingPathComponent("kept.jsonl"), modified: Self.written)
        let gone = try Self.write([Self.read("b", at: "2026-08-12T12:00:00Z")], to: fixture.project.appendingPathComponent("gone.jsonl"), modified: Self.written)
        _ = Self.report(fixture)
        #expect(try Self.storedKeys(fixture).count == 2)

        try FileManager.default.removeItem(at: gone)
        let after = Self.report(fixture)

        let stored = try Self.storedKeys(fixture)
        #expect(stored.count == 1)
        #expect(stored.isSubset(of: Self.keys(of: kept)))
        #expect(after == Self.report(fixture, cached: false))
        #expect(after.share?.tally.total == 1)
    }

    /// A cache file that is not one is ignored and written afresh, never an error.
    @Test
    func aCorruptCacheIsIgnoredAndRewritten() throws {
        let fixture = try Self.fixture()
        let transcript = try Self.write([Self.digest("a", at: "2026-08-12T12:00:00Z")], to: fixture.project.appendingPathComponent("one.jsonl"), modified: Self.written)
        try Data("{\"header\": not json".utf8).write(to: fixture.cache.fileURL)

        let report = Self.report(fixture)

        #expect(report == Self.report(fixture, cached: false))
        let stored = try Self.storedKeys(fixture)
        #expect(stored.count == 1)
        #expect(stored.isSubset(of: Self.keys(of: transcript)))
    }

    /// A cache written by another build holds nothing for this one.
    @Test
    func anotherBuildsCacheIsNotRead() throws {
        let fixture = try Self.fixture()
        let transcript = fixture.project.appendingPathComponent("one.jsonl")
        try Self.write([Self.digest("a", at: "2026-08-12T12:00:00Z")], to: transcript, modified: Self.written)
        _ = Self.report(fixture)
        try Self.write([Self.digest("b", at: "2026-08-13T12:00:00Z")], to: transcript, modified: Self.written)

        var rebuilt = fixture
        rebuilt.cache = TranscriptTallyCache(fileURL: fixture.cache.fileURL, build: "another-build")

        #expect(Self.report(rebuilt).share?.byDay.map(\.day) == ["2026-08-13"])
    }

    /// The keys the cache file holds, which name no transcript by its path.
    static func storedKeys(_ fixture: Fixture) throws -> Set<String> {
        let contents = try JSONDecoder().decode(TranscriptTallyCache.Contents.self, from: Data(contentsOf: fixture.cache.fileURL))
        return Set(contents.transcripts.keys)
    }

    /// The keys `url`'s transcript could be stored under: the sweep spells a temporary directory as it listed it, which may or may not carry `/private`.
    static func keys(of url: URL) -> Set<String> {
        let path = url.path
        let other = path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : "/private" + path
        return Set([path, other].map(TranscriptTallyCache.key(of:)))
    }
}

extension ReportTallyCacheTests {
    struct Fixture {
        let directory: URL
        let project: URL
        let log: URL
        var cache: TranscriptTallyCache
    }
}
