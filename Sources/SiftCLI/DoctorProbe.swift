//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import SiftMCP

/// Runs what an agent would run — a registered hook command, the registered server, the registered binary — inside a scratch directory, with every per-user path pointed into it, so a check writes nothing a person reads.
final class DoctorProbe {
    /// The scratch directory, removed by ``close()``.
    let scratch: URL
    /// The directory every child runs in and every payload names as its `cwd`.
    let workspace: URL
    private let environment: [String: String]
    private let limit: TimeInterval

    /// A probe for `machine`'s environment, with every child stopped after `limit` seconds.
    init(environment machine: [String: String], limit: TimeInterval = 20) throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sift-doctor-\(UUID().uuidString)", isDirectory: true)
        workspace = scratch.appendingPathComponent("workspace", isDirectory: true)
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Every switch this tool reads is dropped, `SIFT_NO_ADVICE` above all, which would make every hook pass by staying silent.
        var environment = machine.filter { !$0.key.hasPrefix("SIFT_") }
        for key in ["CLAUDE_CODE_SESSION_ID", "CLAUDECODE"] {
            environment[key] = nil
        }
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["SIFT_ADVICE_DIR"] = home.appendingPathComponent("advice").path
        for (key, file) in [("SIFT_USAGE_LOG", "usage.jsonl"), ("SIFT_SERVER_LOG", "server.log"), ("SIFT_RUN_LOG", "run.jsonl"), ("SIFT_RUN_LEDGER", "ledger.jsonl")] {
            environment[key] = home.appendingPathComponent(file).path
        }
        self.environment = environment
        self.limit = limit
    }

    func close() {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// `command` run the way an agent runs a hook, through `sh -c`, in the workspace, with `payload` on its input: its exit status and what it printed, or `nil` where it could not be started or outran the limit.
    func run(shell command: String, input: Data = Data()) -> (status: Int32, output: Data)? {
        ExternalReplayHook.launch(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "cd \(ShellWord.quoted(workspace.path)) && \(command)"],
            input: input,
            environment: environment,
            within: limit
        )
    }

    /// `binary --version`'s first line, or why there is none.
    func version(of binary: String) -> Result<String, Refusal> {
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            return .failure(Refusal("\(binary) is not there, or is not executable"))
        }
        guard let run = run(shell: "\(ShellWord.quoted(binary)) --version"), run.status == 0 else {
            return .failure(Refusal("\(binary) --version did not exit 0"))
        }
        let text = String(bytes: run.output, encoding: .utf8) ?? ""
        return .success(text.split(separator: "\n").first.map(String.init) ?? "")
    }

    /// The server `command` starts, asked to initialize and list its tools over stdio: the tools it listed, or why it did not.
    func listedTools(command: String) -> Result<[String], Refusal> {
        let requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
                "protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "sift-doctor", "version": SiftVersion.current],
            ]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
        ]
        var input = Data()
        for request in requests {
            input += (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
            input += Data("\n".utf8)
        }
        guard let run = run(shell: command, input: input) else {
            return .failure(Refusal("did not start, or did not answer within \(Int(limit))s"))
        }
        let replies = (String(bytes: run.output, encoding: .utf8) ?? "").split(separator: "\n").map { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
        guard !replies.isEmpty else {
            return .failure(Refusal("answered nothing (exit \(run.status))"))
        }
        guard replies.allSatisfy({ $0?["jsonrpc"] as? String == "2.0" }) else {
            return .failure(Refusal("printed something other than JSON-RPC on stdout"))
        }
        let listing = replies.compactMap(\.self).first { $0["id"] as? Int == 2 }
        let tools = ((listing?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        guard let tools else {
            return .failure(Refusal("answered no tools/list"))
        }
        return .success(tools)
    }
}

extension DoctorProbe {
    /// Why a probe has no answer, as the check's line says it.
    struct Refusal: Error, Equatable {
        let reason: String

        init(_ reason: String) {
            self.reason = reason
        }
    }
}
