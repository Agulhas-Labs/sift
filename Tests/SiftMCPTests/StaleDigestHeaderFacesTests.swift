//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// The faces put the engine's note about a stale, git-ignored file into the header they frame: the command line, the server and the in-place answer each read it from the digest they were handed.
@Suite(.temporaryDirectories)
struct StaleDigestHeaderFacesTests {
    private static var path: String {
        "Sources/App/Alpha.swift"
    }

    private static var note: String {
        "dirty: 0 (+1 not in git status, reparsed from the live file: \(path))"
    }

    /// An indexed repository whose one file git is then told to overlook and which is then edited.
    private static func repositoryWithAnUnreportedEdit() async throws -> URL {
        let root = try MCPTestRepo.make()
        try await SiftEngine(directory: root).ensureFresh()
        try MCPTestRepo.run(git: ["update-index", "--assume-unchanged", path], in: root)
        try "/// The test type.\nstruct Alpha {\n    let one = 1\n    func go() {}\n    func more() {}\n}\n".write(
            to: root.appendingPathComponent(path), atomically: true, encoding: .utf8
        )
        return root
    }

    @Test
    func theCommandLineHeaderNamesTheReparsedFile() async throws {
        let root = try await Self.repositoryWithAnUnreportedEdit()
        let registry = try RootsRegistry(fileURL: TemporaryDirectory.make("roots").appendingPathComponent("roots.json"))

        let answer = try await DigestCommand.parse([Self.path, "--root", root.path]).answer(registry: registry)

        #expect(answer.components(separatedBy: "\n").first?.contains(Self.note) == true, "\(answer)")
        #expect(answer.contains("func more()"))
    }

    @Test
    func theServerHeaderNamesTheReparsedFile() async throws {
        let root = try await Self.repositoryWithAnUnreportedEdit()
        let registry = try RootsRegistry(fileURL: TemporaryDirectory.make("roots").appendingPathComponent("roots.json"))
        let server = try AnswerHeaderTests.Server(defaultRoot: root, registry: registry)

        let answer = try await server.call("digest", ["target": Self.path])
        await server.close()

        #expect(answer.components(separatedBy: "\n").first?.contains(Self.note) == true, "\(answer)")
        #expect(answer.contains("func more()"))
    }

    @Test
    func theInPlaceAnswerHeaderNamesTheReparsedFile() async throws {
        let root = try await Self.repositoryWithAnUnreportedEdit()

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -n 'func ' \(Self.path)", in: root))

        #expect(answered.reason.contains(Self.note), "\(answered.reason)")
    }
}
