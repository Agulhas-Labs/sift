//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// Covers which digests excuse a window printing more than two hundred lines of a file: the file's whole digest has handed the context the member map such a window would be answered with, while a module's file headings, a few of its lines, one member, or a digest that resolved nothing hand it none of it.
@Suite(.temporaryDirectories) struct WideWindowDigestTests {
    /// The 520-line window from line 400 the benchmark's runs read.
    private static var wide: [String: Any] {
        ["file_path": ListedWideWindowTests.file, "offset": 400, "limit": 520]
    }

    /// A 150-line window beside it.
    private static var narrow: [String: Any] {
        ["file_path": ListedWideWindowTests.file, "offset": 400, "limit": 150]
    }

    /// The hook's lookups for the wide and the narrow window in a context whose one index call was a digest of `target`, recorded with `located` and the source it weighed, `nil` for none, as its writer records it.
    private static func windows(afterDigestOf target: String, located: [String] = [], source: Int?) throws -> (wide: PreToolUseCommand.Lookup?, narrow: PreToolUseCommand.Lookup?) {
        let root = try ListedWideWindowTests.repository()
        let log = try TemporaryDirectory.make("digested").appendingPathComponent("usage.jsonl")
        let usage = UsageLog(fileURL: log)
        usage.record(tool: "digest", target: target, root: root.path, milliseconds: 1, succeeded: true, answer: AnswerBytes(served: 2000, source: source), session: "s1", located: located)
        return (ListedWideWindowTests.lookup(wide, in: root, log: log), ListedWideWindowTests.lookup(narrow, in: root, log: log))
    }

    /// A module digest lists the file under a heading among the module's top-level declarations, which places the file and none of its members: a wide window of it is judged as a cold one, while a narrow one stays located.
    @Test
    func aModuleDigestExcusesNoWideWindow() throws {
        let lookups = try Self.windows(afterDigestOf: "App", located: [ListedWideWindowTests.file, "Sources/App/Depot.swift"], source: nil)

        #expect(lookups.wide != nil)
        #expect(lookups.narrow == nil)
    }

    /// A digest of one line of the file answers with the member that line is in, or the nearest members where it is in none, never the members a wide window prints.
    ///
    /// Recorded as the replay records it, with a source weighed.
    @Test
    func aLineRangeDigestExcusesNoWideWindow() throws {
        let lookups = try Self.windows(afterDigestOf: "\(ListedWideWindowTests.file):455", source: 0)

        #expect(lookups.wide != nil)
        #expect(lookups.narrow == nil)
    }

    /// A member digest that resolved nothing maps nothing of the file: the server records the miss as answered with no source weighed, and the replay records every digest with one.
    @Test(arguments: [nil, 0] as [Int?])
    func aFailedMemberDigestExcusesNoWideWindow(source: Int?) throws {
        let lookups = try Self.windows(afterDigestOf: "Ledger.balance99", source: source)

        #expect(lookups.wide != nil)
    }

    /// A member's digest serves that member, twenty-odd lines, and nothing the log records proves it holds a wide window's lines, so it excuses none.
    @Test
    func aMemberDigestExcusesNoWideWindowItCannotBeShownToCover() throws {
        let lookups = try Self.windows(afterDigestOf: "Ledger.balance3", source: nil)

        #expect(lookups.wide != nil)
        #expect(lookups.narrow == nil)
    }

    /// The hook's own ledger notes a digest as it is asked, before any answer: a line-range digest noted there locates a narrow window and excuses no wide one, while the file's whole digest, a guard here, excuses both.
    @Test(arguments: [("\(ListedWideWindowTests.file):455", false), (ListedWideWindowTests.file, true)] as [(String, Bool)])
    func aDigestTheLedgerNotedExcusesAWideWindowOnlyWhole(target: String, whole: Bool) async throws {
        let root = try ListedWideWindowTests.repository()
        let replay = try HookReplay(directory: TemporaryDirectory.make("ledger-replay"), timeBudget: InPlaceAnswerTests.roomy)
        let path = root.appendingPathComponent(ListedWideWindowTests.file).path

        let rules = await InPlaceAnswerTests.onItsOwnThread {
            let call: [String: Any] = ["session_id": "s1", "tool_name": "mcp__sift__digest", "tool_input": ["target": target]]
            _ = replay.verdict(payload: call, cwd: root.path, at: nil, decides: true)
            return [Self.wide, Self.narrow].map { window in
                let read: [String: Any] = ["session_id": "s1", "tool_name": "Read", "tool_input": window.merging(["file_path": path]) { $1 }]
                return replay.verdict(payload: read, cwd: root.path, at: nil, decides: true)?.rule
            }
        }

        #expect((rules.first == "noLookup") == whole)
        #expect(rules.last == "noLookup")
    }

    /// A guard, passing before and after this rule: the file's whole digest, by path as the server or the replay records it or of the type the file is named for, excuses a window of it however wide.
    @Test(arguments: [(ListedWideWindowTests.file, 48000), (ListedWideWindowTests.file, 0), ("Ledger", 48000)] as [(String, Int)])
    func aWholeDigestOfTheFileStillExcusesAWideWindow(target: String, source: Int) throws {
        let lookups = try Self.windows(afterDigestOf: target, source: source)

        #expect(lookups.wide == nil)
    }
}
