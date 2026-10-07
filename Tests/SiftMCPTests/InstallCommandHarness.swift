//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
@testable import SiftCore
import Testing

/// A scratch machine for `sift install`: a home, an applications directory, and a bin directory holding the binary with the `Sift.md` that ships beside it.
///
/// The only way these tests run the command: ``run(_:answers:)`` injects every seam it has, the PATH names a directory that is not there, and it refuses to run if any path the install would write falls outside the scratch home.
struct InstallCommandHarness {
    let home: URL
    let applications: URL
    let bin: URL
    /// The names the PATH lookup finds, each in ``bin``.
    let onPath: Set<String>
    let claude: FakeClaude
    let codex: FakeCodex

    /// A scratch machine where `onPath` are on the PATH and each of `directories` is made under the home, with `codex` as the only `codex` there is.
    init(onPath: Set<String> = [], directories: [String] = [], codex: FakeCodex = FakeCodex()) throws {
        let root = try TemporaryDirectory.make("install-machine")
        home = root.appendingPathComponent("home", isDirectory: true)
        applications = root.appendingPathComponent("Applications", isDirectory: true)
        bin = root.appendingPathComponent("bin", isDirectory: true)
        self.onPath = onPath
        self.codex = codex
        let manager = FileManager.default
        let home = home
        for directory in [home, applications, bin] + directories.map({ home.appendingPathComponent($0, isDirectory: true) }) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "#!/bin/sh\n".write(to: bin.appendingPathComponent("sift"), atomically: true, encoding: .utf8)
        try Self.rule.write(to: bin.appendingPathComponent("Sift.md"), atomically: true, encoding: .utf8)
        claude = FakeClaude(config: home.appendingPathComponent(".claude.json"))
    }

    /// What the `Sift.md` beside the binary says.
    static var rule: String {
        "# the agent rule\n"
    }

    /// The binary under test, as the command line names it.
    var binary: String {
        bin.appendingPathComponent("sift").path
    }

    /// Every per-user path pointed into the scratch home, the logs included, and a PATH that finds nothing.
    var environment: [String: String] {
        Self.environment(home: home)
    }

    /// The same environment for another scratch `home`.
    static func environment(home: URL) -> [String: String] {
        [
            "CFFIXED_USER_HOME": home.path,
            "HOME": home.path,
            "SIFT_USAGE_LOG": home.appendingPathComponent(".sift/usage.jsonl").path,
            "SIFT_RUN_LOG": home.appendingPathComponent(".sift/run.jsonl").path,
            "PATH": home.appendingPathComponent("no-such-directory").path,
        ]
    }

    /// Detection's view of this machine.
    var machine: AgentDetection.Machine {
        let onPath = onPath
        let bin = bin
        return AgentDetection.Machine(
            environment: environment,
            applications: applications,
            pathLookup: { name in onPath.contains(name) ? bin.appendingPathComponent(name) : nil },
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
    }

    /// Runs `sift install` with `arguments`: at a terminal answering `answers` in turn when they are given, else with no terminal.
    func run(_ arguments: [String], answers: [String?]? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws -> Run {
        let targets = AgentDetection.detect(machine).findings.flatMap(\.targets).map(\.url.path)
        try #require(targets.allSatisfy { $0.hasPrefix(home.path + "/") }, "an install target is outside the scratch home: \(targets)", sourceLocation: sourceLocation)
        let terminal = Terminal(answers: answers ?? [])
        let recorded = RecordedOutput()
        var command = try InstallCommand.parse(arguments)
        command.output = recorded.output
        command.machine = machine
        command.prompt = AllowRunPrompt(isInteractive: answers != nil, ask: { terminal.ask($0) })
        command.claude = claude
        command.codex = codex
        command.arguments = [binary, "install"] + arguments
        command.executable = binary
        var status: Int32 = 0
        do {
            try command.run()
        } catch let exit as ExitCode {
            status = exit.rawValue
        }
        return Run(printed: recorded.printed, status: status, asked: terminal.asked)
    }

    /// Every file under the home, by path relative to it, with its bytes.
    func files() throws -> [String: Data] {
        try Self.files(under: home)
    }

    /// Every file under `root`, by path relative to it, with its bytes.
    static func files(under root: URL) throws -> [String: Data] {
        let prefix = root.resolvingSymlinksInPath().path + "/"
        var files: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            files[path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path] = try Data(contentsOf: url)
        }
        return files
    }
}

extension InstallCommandHarness {
    /// One run: what it printed, the status it exits with, and every question it asked.
    struct Run {
        let printed: String
        let status: Int32
        let asked: [String]

        var lines: [String] {
            printed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
    }

    /// The person at the terminal: answers each question with the next answer, and `nil` once they run out.
    final class Terminal: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String?]
        private var questions: [String] = []

        init(answers: [String?]) {
            self.answers = answers
        }

        var asked: [String] {
            lock.withLock { questions }
        }

        func ask(_ question: String) -> String? {
            lock.withLock {
                questions.append(question)
                return answers.isEmpty ? nil : answers.removeFirst()
            }
        }
    }
}
