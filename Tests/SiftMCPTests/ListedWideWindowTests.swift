//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// Covers how far a `where` or `search` answer that listed a file excuses a window of it: the ranged read around a listed line is the loop working, while a window of hundreds of lines is the file read through a window, and is judged as a cold one is.
@Suite(.temporaryDirectories) struct ListedWideWindowTests {
    static var file: String {
        "Sources/App/Ledger.swift"
    }

    /// A repository holding a 1,123-line Swift file with imports, one class of forty-three members of twenty-five lines each with a blank line between, so a window from line 901 can print two hundred lines and more.
    static func repository() throws -> URL {
        let root = try MCPTestRepo.make()
        let members = (0 ..< 43).map { index in
            let steps = (0 ..< 20).map { "        total += Double(\($0) * input) / max(scale, 1.0) // step \($0) of balance\(index)" }
            return (["    /// The balance figure for slot \(index).", "    func balance\(index)(_ input: Int, scale: Double) -> Double {", "        var total = Double(input) * scale"]
                + steps + ["        return total", "    }"]).joined(separator: "\n")
        }
        let text = "import Foundation\nimport Combine\n\n/// The ledger.\nfinal class Ledger {\n" + members.joined(separator: "\n\n") + "\n}\n"
        try text.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        return root
    }

    /// The usage log of a context whose one index call was a `where` that listed the file, as the server records it.
    private static func listed(in root: URL, log: URL, digest: Bool = false) {
        let usage = UsageLog(fileURL: log)
        usage.record(tool: "where", target: "Ledger", root: root.path, milliseconds: 1, succeeded: true, answer: AnswerBytes(served: 300), session: "s1", located: [file])
        if digest {
            usage.record(tool: "digest", target: file, root: root.path, milliseconds: 1, succeeded: true, answer: AnswerBytes(served: 5000, source: 48000), session: "s1")
        }
    }

    static func payload(_ input: [String: Any], in root: URL) -> [String: Any] {
        var input = input
        if let path = input["file_path"] as? String {
            input["file_path"] = root.appendingPathComponent(path).path
        }
        return ["tool_name": input["command"] == nil ? "Read" : "Bash", "tool_input": input, "session_id": "s1"]
    }

    /// The hook's lookup for `input`, with the index's resolution of a type to its file stood in for: `Ledger` is declared in ``file`` and nothing else is declared anywhere.
    static func lookup(_ input: [String: Any], in root: URL, log: URL) -> PreToolUseCommand.Lookup? {
        PreToolUseCommand.lookup(
            command: nil,
            payload: payload(input, in: root),
            in: root.path,
            noting: SuppressionLog(fileURL: log.deletingLastPathComponent().appendingPathComponent("suppressions.jsonl")),
            digested: DigestedFiles(usageLog: log),
            couldAnswer: { _, _ in true },
            resolvingDigests: { name, _ in name == "Ledger" ? file : nil }
        )
    }

    /// The usage log of a context whose one index call was a `where` that listed the file, and where the lookup `input` would be, `nil` where it is no lookup.
    private static func afterListing(_ input: [String: Any]) throws -> PreToolUseCommand.Lookup? {
        let root = try repository()
        let log = try TemporaryDirectory.make("listed").appendingPathComponent("usage.jsonl")
        listed(in: root, log: log)
        return lookup(input, in: root, log: log)
    }

    /// A window printing hundreds of lines of a file only a listing located is still a lookup, kept for the in-place answer, whichever way the window is spelled: a listing places one line, never the members such a window prints.
    @Test(arguments: [
        ["file_path": file, "limit": 520],
        ["file_path": file, "offset": 1, "limit": 520],
        ["file_path": file, "offset": 0, "limit": 2000],
        ["file_path": file, "offset": 300, "limit": 400],
        ["command": "sed -n '1,520p' \(file)"],
        ["command": "head -520 \(file)"],
    ] as [[String: any Sendable]])
    func aWideWindowOfAFileOnlyAListingLocatedIsStillALookup(input: [String: any Sendable]) throws {
        let root = try Self.repository()
        let log = try TemporaryDirectory.make("listed").appendingPathComponent("usage.jsonl")
        Self.listed(in: root, log: log)

        let lookup = try #require(Self.lookup(input, in: root, log: log))

        #expect(lookup.inPlace?.calls.compactMap(\.readPath).map { SwiftTree.resolve($0, relativeTo: root.path) } == [root.appendingPathComponent(Self.file).path])
    }

    /// A guard, passing before and after the width limit: the ranged read around a listed line is the second half of the loop the listing began, and stays no lookup at all, up to two hundred lines.
    @Test(arguments: [
        ["file_path": file, "offset": 500, "limit": 40],
        ["file_path": file, "limit": 200],
        ["file_path": file, "offset": 901, "limit": 200],
        ["command": "sed -n '480,540p' \(file)"],
    ] as [[String: any Sendable]])
    func aNarrowWindowBesideTheListingIsNoLookup(input: [String: any Sendable]) throws {
        let root = try Self.repository()
        let log = try TemporaryDirectory.make("listed").appendingPathComponent("usage.jsonl")
        Self.listed(in: root, log: log)

        #expect(Self.lookup(input, in: root, log: log) == nil)
    }

    /// A guard, passing before and after the width limit: a whole digest of the file has already handed the context the member map a wide window would be answered with, so it still excuses every window, however wide.
    @Test
    func aDigestOfTheFileStillLocatesAWideWindow() throws {
        let root = try Self.repository()
        let log = try TemporaryDirectory.make("listed").appendingPathComponent("usage.jsonl")
        Self.listed(in: root, log: log, digest: true)

        #expect(Self.lookup(["file_path": Self.file, "limit": 520], in: root, log: log) == nil)
    }

    /// Two hundred lines is the widest window a listing excuses, counted as the lines the window prints: lines 901 to 1,100 are the ranged read beside it, one line more is the file read through a window.
    @Test
    func twoHundredLinesIsTheWidestWindowAListingExcuses() throws {
        #expect(try Self.afterListing(["file_path": Self.file, "offset": 901, "limit": 200]) == nil)
        #expect(try Self.afterListing(["file_path": Self.file, "offset": 901, "limit": 201]) != nil)
    }

    /// A window running past the end of the file is as wide as the lines it prints there, never its limit: from line 924 of 1,123 a 400-line limit prints two hundred, from line 923 it prints one more.
    @Test
    func aWindowPastTheEndOfTheFileIsAsWideAsTheLinesItPrints() throws {
        #expect(try Self.afterListing(["file_path": Self.file, "offset": 924, "limit": 400]) == nil)
        #expect(try Self.afterListing(["file_path": Self.file, "offset": 923, "limit": 400]) != nil)
    }

    /// Every window of the file on the line is counted together, across statements as within one: two reads of 150 and 61 lines are 211 of the file, while 150 and 41 are 191.
    @Test
    func theWindowsOfOneFileAcrossStatementsAreCountedTogether() throws {
        #expect(try Self.afterListing(["command": "sed -n '1,150p' \(Self.file); sed -n '400,460p' \(Self.file)"]) != nil)
        #expect(try Self.afterListing(["command": "sed -n '1,150p' \(Self.file); sed -n '400,440p' \(Self.file)"]) == nil)
    }

    /// End to end on a real index: the 520-line window after the listing is answered in place with the file's digest, a fraction of the lines it stands in for.
    @Test
    func aWideWindowAfterAListingIsAnsweredInPlace() async throws {
        let root = try Self.repository()
        try await SiftEngine(directory: root).ensureFresh()
        let directory = try TemporaryDirectory.make("listed")
        let log = directory.appendingPathComponent("usage.jsonl")
        Self.listed(in: root, log: log)
        let backoff = try InPlaceAnswerTests.backoff()
        let output = await InPlaceAnswerTests.onItsOwnThread { () -> String? in
            let payload = Self.payload(["file_path": Self.file, "limit": 520], in: root)
            guard let lookup = Self.lookup(["file_path": Self.file, "limit": 520], in: root, log: log) else { return nil }
            return PreToolUseCommand.respond(
                to: lookup,
                session: "s1",
                context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil),
                payload: payload,
                cwd: root.path,
                ledger: AdviceLedger(directory: directory.appendingPathComponent("advice")),
                usage: UsageLog(fileURL: log),
                suppressions: SuppressionLog(fileURL: directory.appendingPathComponent("suppressions.jsonl")),
                answerer: { match, gone, _ in InPlaceAnswerer.answer(match, serverGone: gone, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff) }
            )
        }
        let data = try #require(output.map { Data($0.utf8) })
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let specific = try #require(object["hookSpecificOutput"] as? [String: Any])
        let reason = try #require(specific["permissionDecisionReason"] as? String)
        let window = try String(contentsOf: root.appendingPathComponent(Self.file), encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).prefix(520).joined(separator: "\n")

        #expect(specific["permissionDecision"] as? String == "deny")
        #expect(reason.hasPrefix("sift answered this with `digest \(Self.file)`"))
        #expect(reason.contains("func balance41("))
        #expect(reason.utf8.count * 4 < window.utf8.count)
    }
}
