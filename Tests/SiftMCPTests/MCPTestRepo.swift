//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// Assertion-free plumbing: a disposable committed git repo with one Swift type for server tests.
struct MCPTestRepo {
    /// `extraFiles` adds that many trivial sources, for the one caller that needs this helper's own output to pass what a pipe holds — `git commit` prints a line per file it creates, and nothing else here can be made to fill one.
    static func make(declaring type: String = "Alpha", extending extended: String? = nil, extraFiles: Int = 0) throws -> URL {
        try make(at: TemporaryDirectory.make("mcp"), declaring: type, extending: extended, extraFiles: extraFiles)
    }

    /// The same repository in a directory the caller made — for a caller that builds it off the test's own task, where the test's temporary-directory scope does not reach.
    static func make(at root: URL, declaring type: String = "Alpha", extending extended: String? = nil, extraFiles: Int = 0) throws -> URL {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/App"),
            withIntermediateDirectories: true
        )
        try "/// The test type.\nstruct \(type) {\n    let one = 1\n    func go() {}\n}\n".write(
            to: root.appendingPathComponent("Sources/App/\(type).swift"),
            atomically: true,
            encoding: .utf8
        )
        // Padded names rather than more files: `create mode 100644 <path>` carries the bytes, so a long
        // path gets past 64 KB in hundreds of writes instead of thousands, and the fixture stays quick.
        let padding = String(repeating: "Nested", count: 7)
        for index in 0 ..< extraFiles {
            try "struct Filler\(index) {}\n".write(
                to: root.appendingPathComponent("Sources/App/\(padding)Filler\(index).swift"),
                atomically: true,
                encoding: .utf8
            )
        }
        if let extended {
            try "extension \(extended) {\n    func spin() {}\n}\n".write(
                to: root.appendingPathComponent("Sources/App/Extensions.swift"),
                atomically: true,
                encoding: .utf8
            )
        }
        for arguments in [
            ["init", "-b", "main"],
            ["config", "user.email", "test@example.com"],
            ["config", "user.name", "Tester"],
            ["add", "-A"],
            ["commit", "-m", "seed"],
        ] {
            try run(git: arguments, in: root)
        }
        return root.resolvingSymlinksInPath()
    }

    /// A linked worktree of `root` at the same commit — the shape a change-producing subagent is given.
    ///
    /// Sited outside the repository rather than inside it, so the worktree's own file enumeration cannot pick up the parent's sources and make the two trees look alike for the wrong reason — in a temporary directory of its own, which the test's scope removes, rather than loose beside the repository in `$TMPDIR`, where nothing would.
    static func worktree(of root: URL, named name: String) throws -> URL {
        let path = try TemporaryDirectory.make("worktree")
            .appendingPathComponent("\(root.lastPathComponent)-\(name)")
        try run(git: ["worktree", "add", "-b", name, path.path, "HEAD"], in: root)
        return path.resolvingSymlinksInPath()
    }

    /// Writes `files` — repository-relative path to contents — into `root`, and commits them.
    static func add(_ files: [String: String], to root: URL) throws {
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try run(git: ["add", "-A"], in: root)
        try run(git: ["commit", "-m", "fixture"], in: root)
    }

    /// Builds `root` as a SwiftPM package with an index store at `.build/index/store`, which `where --refs` reads.
    ///
    /// SwiftPM's temporary directory is one of the caller's scope: SwiftPM files a lock for the scratch path and one for the workspace state in `$TMPDIR`, named for the package's own path, and never removes either — and the driver leaves its `TemporaryDirectory.*` there too — so pointed anywhere else they outlive the repository.
    static func build(_ root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = [
            "build", "--package-path", root.path,
            "-Xswiftc", "-index-store-path", "-Xswiftc", root.appendingPathComponent(".build/index/store").path,
        ]
        let swiftPMTemporary = try TemporaryDirectory.make("swiftpm")
        process.environment = ProcessInfo.processInfo.environment.merging(["TMPDIR": swiftPMTemporary.path + "/"]) { _, redirected in redirected }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let streams = ProcessStreams.drain(stdout: stdout, stderr: stderr)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            struct BuildError: Error {
                let message: String
            }
            throw BuildError(message: String(data: streams.output + streams.failure, encoding: .utf8).map { String($0.suffix(600)) } ?? "")
        }
    }

    static func run(git arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // A suite run from a git hook inherits that hook's repository through these, and would commit into it.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Read to the end before waiting, both streams, through the one helper the rest of the codebase
        // uses. A single pipe attached to both and never read at all is the strongest form of the
        // deadlock `ProcessStreams` exists to prevent: a pipe holds 64 KB, `git commit` prints a
        // `create mode` line per file it adds, and past that git blocks in `write` while `waitUntilExit`
        // waits for a process that will never exit. Unreachable while every fixture commits two files,
        // which is exactly what hides it.
        let streams = ProcessStreams.drain(stdout: stdout, stderr: stderr)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            struct GitSetupError: Error {
                let message: String
            }
            let output = [streams.output, streams.failure]
                .compactMap { String(data: $0, encoding: .utf8) }
                .joined()
            throw GitSetupError(message: "git \(arguments.joined(separator: " ")) failed in test: \(output)")
        }
    }
}
