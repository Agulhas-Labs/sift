//
// Copyright © Agulhas Labs
//

import Foundation
import Testing

/// `--root` on a folder that is no git work tree, through the built binary and a home of its own: the answer is a refusal naming the folder, never the answer from a repository the registry happens to know.
@Suite(.temporaryDirectories)
struct CLINamedRootTests {
    @Test
    func everyVerbRefusesANamedFolderThatIsNoWorkTreeRatherThanAnsweringFromAnIndexedRepository() async throws {
        let repo = try await InPlaceAnswerTests.indexedRepository()
        let scratch = try TemporaryDirectory.make("named-root").appendingPathComponent("named-root")
        let home = scratch.appendingPathComponent("home")
        let plain = scratch.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try "struct Gizmo {}\n".write(to: plain.appendingPathComponent("Gizmo.swift"), atomically: true, encoding: .utf8)
        // Registers the repository in this home's registry, so the refused runs below have something to wrongly adopt.
        let known = try Self.run(["where", "Depot", "--root", repo.path], home: home)
        #expect(known.status == 0)

        for verb in [["where", "Depot"], ["digest", "Depot"], ["search", "name:Depot"], ["strings", "Depot"]] {
            let answer = try Self.run(verb + ["--root", plain.path], home: home)

            #expect(answer.status != 0, "`sift \(verb.joined(separator: " "))` answered from another tree")
            #expect(answer.text.contains("not a git work tree"))
            #expect(answer.text.contains(plain.lastPathComponent))
            #expect(!answer.text.contains("Depot.swift"))
        }
    }

    private static func run(_ arguments: [String], home: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> (status: Int32, text: String) {
        let binary = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)", sourceLocation: sourceLocation)
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = home.path
        environment["HOME"] = home.path
        environment["SIFT_USAGE_LOG"] = home.appendingPathComponent("usage.jsonl").path
        environment["SIFT_ADVICE_DIR"] = home.appendingPathComponent("advice").path
        environment["CLAUDE_CODE_SESSION_ID"] = nil
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try (process.terminationStatus, #require(String(bytes: printed, encoding: .utf8), sourceLocation: sourceLocation))
    }
}
