//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// Covers `sift run` with and without the mark the hook leaves on a build it rewrote: the line saying so comes first, and nothing else about the run changes.
@Suite(.temporaryDirectories)
struct RunRewriteNoticeTests {
    /// One in-process run of a stand-in `swift test` handed `arguments`, in `given` (a fresh directory where `nil`).
    private static func ran(_ arguments: [String], in given: URL? = nil) throws -> Ran {
        let directory = try given ?? TemporaryDirectory.make("run-rewrite-notice")
        let handed = directory.appendingPathComponent("handed.txt")
        let script = directory.appendingPathComponent("swift")
        let body = "#!/bin/sh\necho \"$@\" > '\(handed.path)'\necho '/tmp/Widget.swift:3:1: error: cannot find Gadget in scope'\nexit 65\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let file = directory.appendingPathComponent("run.jsonl")
        try? FileManager.default.removeItem(at: file)
        let recorded = RecordedOutput()

        var command = try RunCommand.parse(["--", script.path] + arguments)
        command.log = RunUsageLog(fileURL: file)
        command.writesUnder = directory
        command.output = recorded.output
        var exit: Int32?
        do {
            try command.run()
        } catch let code as ExitCode {
            exit = code.rawValue
        }
        let line = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").first.map(String.init) ?? ""
        let entry = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        let argv = try String(contentsOf: handed, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return Ran(printed: recorded.printed, handed: argv, exit: exit, invocation: entry?["invocation"] as? String, shown: entry?["shown"] as? Int)
    }

    /// A run carrying the mark opens with the line saying the hook ran it, before anything the run printed.
    @Test
    func aMarkedRunPrintsTheNoticeFirst() throws {
        let marked = try Self.ran(["test", "--filter", "Probe", RunRewrite.marker])

        #expect(marked.printed.hasPrefix("sift: the hook rewrote this to"))
        #expect(marked.printed.components(separatedBy: "\n").first?.hasSuffix("test --filter Probe 2>&1 | cat`; full log on the `raw:` line.") == true)
    }

    /// The notice is a line the run printed, so the run log's count of lines out includes it.
    @Test
    func theNoticeIsCountedInTheLinesOut() throws {
        let directory = try TemporaryDirectory.make("run-rewrite-count")
        let marked = try Self.ran(["test", RunRewrite.marker], in: directory)
        let typed = try Self.ran(["test"], in: directory)

        #expect(try marked.shown == #require(typed.shown) + 1)
    }

    /// A run anyone typed prints no such line.
    @Test
    func anUnmarkedRunPrintsNoNotice() throws {
        let typed = try Self.ran(["test", "--filter", "Probe"])

        #expect(!typed.printed.contains("the hook ran this"))
    }

    /// The mark never reaches the wrapped command, and the exit code and run log's invocation hash are the unmarked run's.
    @Test
    func theMarkChangesNothingButTheNotice() throws {
        let directory = try TemporaryDirectory.make("run-rewrite-same-command")
        let marked = try Self.ran(["test", "--filter", "Probe", RunRewrite.marker], in: directory)
        let typed = try Self.ran(["test", "--filter", "Probe"], in: directory)

        #expect(marked.handed == "test --filter Probe")
        #expect(marked.exit != nil)
        #expect(marked.exit == typed.exit)
        #expect(marked.invocation != nil)
        #expect(marked.invocation == typed.invocation)
    }
}

private extension RunRewriteNoticeTests {
    /// What one in-process run of a stand-in `swift test` printed, the arguments the stand-in was handed, the exit code it ended on, and the invocation hash its run log line carries.
    struct Ran {
        let printed: String
        let handed: String
        let exit: Int32?
        let invocation: String?
        let shown: Int?
    }
}
