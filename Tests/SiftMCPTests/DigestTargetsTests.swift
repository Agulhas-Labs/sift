//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// Several `digest` targets in one call, on the faces that take them and the records that count them.
///
/// Each target is one name however it is spelled: the CLI takes one per argument, the MCP face one per `target` and several in `targets`, and neither splits a value on whitespace — a path with a space in it is one file. The usage log and the audit then read each target as its own name, because a joined string is a name nobody asked for.
@Suite(.temporaryDirectories)
struct DigestTargetsTests {
    private static func temporaryRegistry() throws -> RootsRegistry {
        try RootsRegistry(fileURL: TemporaryDirectory.make("roots").appendingPathComponent("roots.json"))
    }

    /// A repository holding `Sources/My App/ContentView.swift` beside the helper's own `Alpha`.
    private static func spacedRepository() throws -> URL {
        let root = try MCPTestRepo.make()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/My App"), withIntermediateDirectories: true)
        try "struct ContentView {\n    let one = 1\n}\n".write(
            to: root.appendingPathComponent("Sources/My App/ContentView.swift"), atomically: true, encoding: .utf8
        )
        return root
    }

    // MARK: - The CLI

    @Test
    func aQuotedPathWithASpaceIsOneTargetOnTheCommandLine() async throws {
        let root = try Self.spacedRepository()

        let answer = try await DigestCommand.parse(["Sources/My App/ContentView.swift", "--root", root.path])
            .answer(registry: Self.temporaryRegistry())

        #expect(answer.contains("struct ContentView"))
        #expect(!answer.contains("no indexed file matches"))
    }

    @Test
    func eachArgumentIsAnswered() async throws {
        let root = try Self.spacedRepository()

        let answer = try await DigestCommand.parse(["Sources/My App/ContentView.swift", "Alpha.go()", "--root", root.path])
            .answer(registry: Self.temporaryRegistry())

        #expect(answer.contains("struct ContentView"))
        #expect(answer.contains("Alpha.go() — func"))
    }

    // MARK: - The MCP face's reading of its arguments

    @Test
    func aTargetIsNeverSplit() throws {
        #expect(try MCPServer.digestTargets(in: ["target": "Sources/My App/ContentView.swift"]) == ["Sources/My App/ContentView.swift"])
        #expect(try MCPServer.digestTargets(in: ["target": "Alpha", "targets": ["Beta", "Gamma"]]) == ["Alpha", "Beta", "Gamma"])
        #expect(try MCPServer.digestTargets(in: [:]).isEmpty)
    }

    /// The note is for a spaced value that named nothing — never beside a spaced path that resolved, nor on a miss with no space in it.
    @Test
    func theSpacedTargetNoteIsOnlyForASpacedMiss() {
        #expect(MCPServer.spacedTargetNote(arguments: ["target": "Alpha Gizmo"], missed: true) != nil)
        #expect(MCPServer.spacedTargetNote(arguments: ["target": "Sources/My App/ContentView.swift"], missed: false) == nil)
        #expect(MCPServer.spacedTargetNote(arguments: ["target": "Gizmo"], missed: true) == nil)
    }

    /// A path-shaped target never gets the note, missed or not: a gitignored file with a space in its path answers correctly (the exclusion, not a miss) and the note above it would second-guess a right answer; a mistyped spaced path is still one path wrongly spelled, not several names run together.
    @Test
    func thePathShapedTargetNeverGetsTheSpacedNoteEvenOnAMiss() {
        #expect(MCPServer.spacedTargetNote(arguments: ["target": "Sources/My App/Ignored.swift"], missed: true) == nil)
        #expect(MCPServer.spacedTargetNote(arguments: ["target": "My App.swift"], missed: true) == nil)
        // No `/` and no `.swift` suffix (it ends in the range instead) — only the line-range check catches this one.
        #expect(MCPServer.spacedTargetNote(arguments: ["target": "My File.swift:12-40"], missed: true) == nil)
    }

    // MARK: - The records

    @Test
    func everyTargetIsReadOnceEach() {
        #expect(IndexCallTarget.all(["targets": ["Alpha", "Beta"]]) == ["Alpha", "Beta"])
        #expect(IndexCallTarget.all(["target": "My App/ContentView.swift"]) == ["My App/ContentView.swift"])
        #expect(IndexCallTarget.all(["symbol": "Alpha"]) == ["Alpha"])
        // What a call is matched by stays one string, computed alike at both ends of the match.
        #expect(IndexCallTarget.of(["targets": ["Alpha", "Beta"]]) == "Alpha Beta")
    }

    @Test
    func theUsageLogRecordsSeveralTargetsAsAListAndTalliesEach() throws {
        let file = try TemporaryDirectory.make("usage").appendingPathComponent("usage.jsonl")
        let log = UsageLog(fileURL: file)
        log.record(tool: "digest", target: "Alpha Beta", targets: ["Alpha", "Beta"], root: "/repo", milliseconds: 1, succeeded: true)
        log.record(tool: "digest", target: "Alpha", targets: ["Alpha"], root: "/repo", milliseconds: 1, succeeded: true)

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        let several = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        let single = try #require(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])

        #expect(several["targets"] as? [String] == ["Alpha", "Beta"])
        #expect(several["target"] == nil)
        // One target is written exactly as it always was.
        #expect(single["target"] as? String == "Alpha")
        #expect(single["targets"] == nil)

        let tallied = try UsageScan.load(fileURL: file).get().topTargets()
        #expect(tallied.first { $0.label == "digest Alpha" }?.count == 2)
        #expect(tallied.first { $0.label == "digest Beta" }?.count == 1)
        #expect(!tallied.contains { $0.label == "digest Alpha Beta" })
    }

    // MARK: - Line-range targets

    @Test
    func aLineRangeIsReadTheSameWayEverywhere() {
        let reversed = DigestLineRange.parse("Sources/App/ChuteTap.swift:40-12")

        #expect(reversed?.path == "Sources/App/ChuteTap.swift")
        #expect(reversed?.start == 12)
        #expect(reversed?.end == 40)
        #expect(reversed?.suffix == ":40-12")
        #expect(DigestLineRange.parse("ChuteTap.swift:10:9:")?.start == 10)
        #expect(DigestLineRange.parse("ChuteTap.swift:10:9:")?.end == 10)
        // A labelled member is a name, not a line range, whatever its colons.
        #expect(DigestLineRange.parse("ChuteTap.save(_:to:)") == nil)
        #expect(DigestLineRange.parse("Sources/App/ChuteTap.swift") == nil)
    }

    /// The audit credits a line-range target's file by its path, not by the accident of splitting at the dot before `swift`.
    @Test
    func theAuditCreditsALineRangeByItsFile() {
        #expect(TranscriptScan.locatedNames(in: ["target": "Sources/App/ChuteTap.swift:12-40"]) == ["ChuteTap"])
        #expect(TranscriptScan.locatedNames(in: ["targets": ["Sources/App/ChuteTap.swift:3:5:", "BayCard"]]) == ["ChuteTap", "BayCard"])
    }

    /// A line range sent under `path:` — the key a caller reaching for a file sends — is healed into `digest`'s `target:`, and only `digest`'s.
    @Test
    func aLineRangeUnderPathIsHealedForDigestOnly() {
        #expect(ArgumentAlias.isNameShaped("Sources/App/ChuteTap.swift:12-40", allowingRange: true))
        #expect(ArgumentAlias.isNameShaped("ChuteTap.swift:10:9:", allowingRange: true))
        #expect(ArgumentAlias.resolve(tool: "digest", arguments: ["path": "Sources/App/ChuteTap.swift:12"])?.given == "path")
        #expect(ArgumentAlias.resolve(tool: "digest", arguments: ["query": "Sources/App/ChuteTap.swift:12"])?.wanted == "target")
        #expect(ArgumentAlias.resolve(tool: "where", arguments: ["path": "Sources/App/ChuteTap.swift:12"]) == nil)
    }

    /// The range shape heals only for `digest` — `where` refuses a line range under any of its carrying keys exactly as it refuses any other missing `symbol:`, rather than healing it into a lookup that then reports "no declarations found" for lines a symbol index was never asked about.
    @Test
    func aLineRangeIsNeverHealedForWhere() {
        #expect(!ArgumentAlias.isNameShaped("Shapes.swift:12:5:", allowingRange: false))
        #expect(!ArgumentAlias.isNameShaped("Shapes.swift:12", allowingRange: false))
        #expect(ArgumentAlias.resolve(tool: "where", arguments: ["target": "Shapes.swift:12:5:"]) == nil)
        #expect(ArgumentAlias.resolve(tool: "where", arguments: ["query": "Shapes.swift:12"]) == nil)
    }

    /// The audit credits each of `targets`, and reads a spaced `target` whole — an old transcript scores as it always did.
    @Test
    func theAuditCreditsEachTargetAndNeverSplitsOne() {
        #expect(TranscriptScan.locatedNames(in: ["targets": ["LibCore.CrateData", "Engine.start"]]) == ["LibCore", "CrateData", "Engine", "start"])
        #expect(TranscriptScan.locatedNames(in: ["target": "Sources/My App/ContentView.swift"]) == ["ContentView"])
        #expect(TranscriptScan.locatedNames(in: ["target": "Engine Fuel"]) == ["Engine Fuel"])
    }
}
