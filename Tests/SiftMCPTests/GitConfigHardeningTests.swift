//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// A repository's own `.git/config` names programs git starts (`core.fsmonitor` on every command that loads the index, and the hooks in `core.hooksPath`), and a lookup runs unprompted under an allow rule: no lookup may start one.
///
/// Driven through the built binary, because the claim is about every process it spawns, the hook's included: a repository whose fsmonitor command and `post-index-change` hook each touch a marker file, and each lookup, and the Stop gate, run against it by the real `sift`.
@Suite(.temporaryDirectories)
struct GitConfigHardeningTests {
    /// The program the repository's config names ran for a plain `git status`, so the lookups below have something to fail to start.
    @Test
    func theProbeHookRunsWhenGitIsRunPlainly() throws {
        let scene = try Scene()

        _ = try scene.git(["status", "--porcelain"])

        #expect(scene.hookRan, "the fsmonitor hook was never started by a plain `git status`: the probe proves nothing")
    }

    /// The repository's git hook ran for a plain `git add --all`, the command the Stop gate's tree key runs, so the test below has something to fail to start.
    @Test
    func theProbeGitHookRunsWhenGitAddsPlainly() throws {
        let scene = try Scene()

        _ = try scene.git(["add", "--all"])

        #expect(scene.gitHookRan, "the post-index-change hook was never started by a plain `git add --all`: the probe proves nothing")
    }

    @Test(arguments: Lookup.allCases)
    func aLookupNeverStartsTheProgramTheRepositoryConfigNames(lookup: Lookup) throws {
        let scene = try Scene()
        let run = try scene.run(lookup)

        #expect(run.status == 0, "\(lookup) exited \(run.status): \(run.printed)")
        if lookup == .preToolUseRead {
            #expect(!run.printed.isEmpty, "the hook let the read through, so it never reached git")
        }
        #expect(!scene.hookRan, "\(lookup) started the repository's core.fsmonitor program")
        #expect(!scene.gitHookRan, "\(lookup) started a git hook of the repository")
    }
}

extension GitConfigHardeningTests {
    /// Each lookup a repository's config must not reach a program through: the four queries, a query at a revision, the hook's answer to a read of a Swift file, and the Stop gate's key of the tree after an edit.
    enum Lookup: String, CaseIterable, CustomTestStringConvertible {
        case digest
        case digestAtRevision
        case whereSymbol
        case search
        case strings
        case preToolUseRead
        case stop

        var testDescription: String {
            rawValue
        }
    }

    /// A repository in the test's own temporary directory, one committed Swift file and one untracked, an fsmonitor hook in its config and a `post-index-change` hook in its `core.hooksPath` that each touch a marker; a home, advice directory and Claude configuration of the test's own.
    struct Scene {
        let repo: URL
        let home: URL
        let file: URL
        let marker: URL
        let gitHookMarker: URL

        init() throws {
            repo = try TemporaryDirectory.make("hardening-repo")
            home = try TemporaryDirectory.make("hardening-home")
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            let inside = repo.resolvingSymlinksInPath().path
            guard inside.hasPrefix(temporary + "/") else {
                throw OutsideTemporaryDirectory(path: inside)
            }
            marker = home.appendingPathComponent("hook-ran")
            gitHookMarker = home.appendingPathComponent("git-hook-ran")
            file = repo.appendingPathComponent("Sources/App/Depot.swift")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Long enough that a whole-file Read is answered from the index, which is what asks git about the tree.
            let members = (1 ... 150).map { "    func member\($0)() -> Int {\n        let value = \($0)\n        return value + label.count\n    }\n" }
            try ("struct Depot {\n    let label = \"Hardening probe label\"\n" + members.joined(separator: "\n") + "}\n").write(to: file, atomically: true, encoding: .utf8)
            _ = try git(["init", "-q"])
            _ = try git(["add", "."])
            _ = try git(["-c", "user.name=probe", "-c", "user.email=probe@example.com", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "probe"])
            // Written after the commit, so nothing the fixture itself ran can have touched the marker.
            // Untracked, so a `git add --all` changes the index and the hook below has a reason to fire.
            try "struct Extra {}\n".write(to: repo.appendingPathComponent("Sources/App/Extra.swift"), atomically: true, encoding: .utf8)
            let hooks = home.appendingPathComponent("hooks")
            try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
            let gitHook = hooks.appendingPathComponent("post-index-change")
            try "#!/bin/sh\ntouch '\(gitHookMarker.path)'\n".write(to: gitHook, atomically: true, encoding: .utf8)
            #expect(chmod(gitHook.path, 0o755) == 0)
            let hook = home.appendingPathComponent("hook.sh")
            try "#!/bin/sh\ntouch '\(marker.path)'\nprintf 'token\\0'\n".write(to: hook, atomically: true, encoding: .utf8)
            #expect(chmod(hook.path, 0o755) == 0)
            let config = repo.appendingPathComponent(".git/config")
            let existing = try String(contentsOf: config, encoding: .utf8)
            try (existing + "[core]\n\tfsmonitor = \(hook.path)\n\thooksPath = \(hooks.path)\n").write(to: config, atomically: true, encoding: .utf8)
        }

        var hookRan: Bool {
            FileManager.default.fileExists(atPath: marker.path)
        }

        var gitHookRan: Bool {
            FileManager.default.fileExists(atPath: gitHookMarker.path)
        }

        /// The environment of every process the scene spawns: no `GIT_*` variable, a home and advice directory of its own, and an empty Claude Code configuration so the user's settings do not decide what a hook says.
        var environment: [String: String] {
            var environment = ProcessEnvironment.withoutGit()
            environment["CFFIXED_USER_HOME"] = home.path
            environment["SIFT_HOME"] = home.appendingPathComponent("sift").path
            environment["SIFT_ADVICE_DIR"] = home.appendingPathComponent("advice").path
            environment["SIFT_USAGE_LOG"] = home.appendingPathComponent("usage.jsonl").path
            environment["SIFT_NO_ADVICE"] = nil
            environment["CLAUDE_CODE_SESSION_ID"] = nil
            environment["CLAUDE_CONFIG_DIR"] = home.appendingPathComponent("claude").path
            environment["CLAUDE_PROJECT_DIR"] = nil
            return environment
        }

        /// A `git` in the repository, run to its end.
        func git(_ arguments: [String]) throws -> (status: Int32, printed: String) {
            try spawn(URL(fileURLWithPath: "/usr/bin/git"), arguments, stdin: nil)
        }

        func run(_ lookup: Lookup, sourceLocation: SourceLocation = #_sourceLocation) throws -> (status: Int32, printed: String) {
            let binary = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)", sourceLocation: sourceLocation)
            let root = ["--root", repo.path]
            switch lookup {
            case .digest: return try spawn(binary, ["digest", file.path] + root, stdin: nil)
            case .digestAtRevision: return try spawn(binary, ["digest", file.path, "--at", "HEAD"] + root, stdin: nil)
            case .whereSymbol: return try spawn(binary, ["where", "Depot"] + root, stdin: nil)
            case .search: return try spawn(binary, ["search", "kind:struct"] + root, stdin: nil)
            case .strings: return try spawn(binary, ["strings", "Hardening probe label"] + root, stdin: nil)
            case .stop:
                let transcript = home.appendingPathComponent("transcript.jsonl")
                let lines = [StopGateFixture.edit("t1", path: file.path), StopGateFixture.result("t1")]
                let text = try lines.map { try String(bytes: JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), encoding: .utf8) ?? "" }.joined(separator: "\n")
                try text.write(to: transcript, atomically: true, encoding: .utf8)
                let payload: [String: Any] = [
                    "hook_event_name": "Stop", "session_id": "hardening-session", "cwd": repo.path,
                    "stop_hook_active": false, "transcript_path": transcript.path,
                ]
                return try spawn(binary, ["stop"], stdin: JSONSerialization.data(withJSONObject: payload))
            case .preToolUseRead:
                let payload: [String: Any] = [
                    "session_id": "hardening-session", "cwd": repo.path, "hook_event_name": "PreToolUse",
                    "tool_name": "Read", "tool_input": ["file_path": file.path], "tool_use_id": "t1",
                ]
                return try spawn(binary, ["pre-tool-use"], stdin: JSONSerialization.data(withJSONObject: payload))
            }
        }

        private func spawn(_ executable: URL, _ arguments: [String], stdin: Data?) throws -> (status: Int32, printed: String) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = repo
            process.environment = environment
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            try process.run()
            if let stdin {
                try input.fileHandleForWriting.write(contentsOf: stdin)
            }
            input.fileHandleForWriting.closeFile()
            let printed = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(bytes: printed, encoding: .utf8) ?? "")
        }
    }

    struct OutsideTemporaryDirectory: Error {
        let path: String
    }
}
