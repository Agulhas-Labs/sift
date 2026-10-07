//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A committed repository holding `Depot.swift`, a ledger and a marks store of its own, and transcripts written beside them.
struct StopGateFixture {
    let repo: URL
    let marks: ReuseNudgeMarks
    let transcripts: URL

    init(package: Bool = true) throws {
        repo = try MCPTestRepo.make(declaring: "Depot")
        if package {
            try "// swift-tools-version:6.0\nimport PackageDescription\nlet package = Package(name: \"Depot\")\n"
                .write(to: repo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        }
        marks = try ReuseNudgeMarks(directory: TemporaryDirectory.make("stop-marks"))
        transcripts = try TemporaryDirectory.make("stop-transcripts")
    }

    var depot: String {
        repo.appendingPathComponent("Sources/App/Depot.swift").path
    }

    var ledger: RunLedger {
        RunLedger.inRepository(at: repo)
    }

    /// Creates an untracked Swift file at the repository-relative `path`, its directories included, and returns its absolute path.
    func file(_ path: String) throws -> String {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "struct Probe {}\n".write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// Writes `lines` as a transcript and returns its path.
    func transcript(_ lines: [[String: Any]], named name: String = "session") throws -> String {
        let url = transcripts.appendingPathComponent("\(name).jsonl")
        let text = try lines.map { try String(bytes: JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), encoding: .utf8) ?? "" }
        try (text.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// What the hook printed for a stop in session `s1` with `fields` added, run off the concurrency pool as the hook's main thread would.
    func hook(_ fields: [String: Any], now: Date = Date()) async -> String {
        var payload: [String: Any] = ["hook_event_name": "Stop", "session_id": "s1", "cwd": repo.path, "stop_hook_active": false]
        payload.merge(fields) { $1 }
        let recorded = RecordedOutput()
        let input = ResultBox<[String: Any]>()
        input.value = payload
        let marks = marks
        await InPlaceAnswerTests.onItsOwnThread {
            StopCommand.answer(to: input.value ?? [:], output: recorded.output, marks: marks, timeBudget: InPlaceAnswerTests.roomy, now: now)
        }
        return recorded.printed
    }

    /// The reason a printed block carries, or `nil` where nothing was printed.
    static func blockReason(of printed: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String? {
        guard !printed.isEmpty else { return nil }
        let object = try JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any]
        #expect(object?["decision"] as? String == "block", sourceLocation: sourceLocation)
        return object?["reason"] as? String
    }

    static func edit(_ id: String, path: String, tool: String = "Edit", cwd: String? = nil, sidechain: Bool = false) -> [String: Any] {
        let use: [String: Any] = ["type": "tool_use", "id": id, "name": tool, "input": ["file_path": path, "old_string": "one", "new_string": "two"]]
        var line: [String: Any] = ["type": "assistant", "isSidechain": sidechain, "message": ["role": "assistant", "content": [use]]]
        line["cwd"] = cwd
        return line
    }

    static func bash(_ id: String, command: String, cwd: String? = nil) -> [String: Any] {
        let use: [String: Any] = ["type": "tool_use", "id": id, "name": "Bash", "input": ["command": command]]
        var line: [String: Any] = ["type": "assistant", "isSidechain": false, "message": ["role": "assistant", "content": [use]]]
        line["cwd"] = cwd
        return line
    }

    static func result(_ id: String, failed: Bool = false, sidechain: Bool = false) -> [String: Any] {
        let block: [String: Any] = ["type": "tool_result", "tool_use_id": id, "is_error": failed, "content": failed ? "Exit code 1" : "ok"]
        return ["type": "user", "isSidechain": sidechain, "message": ["role": "user", "content": [block]]]
    }

    /// Files the tree `checkout` holds now as `sift run` does after a green `swift build` there: in that checkout's own green-build file, spelled out here rather than through the API that names it.
    static func recordGreenBuild(in checkout: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let tree = try #require(TreeKey.of(repositoryRoot: checkout), sourceLocation: sourceLocation)
        RunLedger(fileURL: SiftPaths.cache(in: checkout).appendingPathComponent("green-builds.json")).record(RunLedger.Record(
            tree: tree.value,
            command: "swift build",
            toolchain: "",
            finishedAt: Date(),
            log: nil,
            milliseconds: 1000,
            checkout: checkout.path,
            workingDirectory: "."
        ))
    }

    static func record(tree: String, command: String, workingDirectory: String = ".") -> RunLedger.Record {
        RunLedger.Record(tree: tree, command: command, toolchain: "swift-6", finishedAt: Date(), log: nil, milliseconds: 1000, workingDirectory: workingDirectory)
    }
}
