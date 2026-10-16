//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// `--decl` is refused beside `--refs` and `--files` on the command line, in the one line the spec names (the server's refusal is pinned in `MCPServerTests`).
@Suite(.temporaryDirectories)
struct WhereDeclarationsOnlyRefusalTests {
    private static func refusal(_ arguments: [String]) -> String? {
        do {
            _ = try WhereCommand.parse(arguments)
            return nil
        } catch {
            return WhereCommand.message(for: error)
        }
    }

    @Test
    func theCommandLineRefusesRefsAndFilesBesideDecl() {
        let line = "--decl answers where Alpha is declared, and --refs and --files every place it is written: pass one."

        #expect(Self.refusal(["Alpha", "--decl", "--refs"]) == line)
        #expect(Self.refusal(["Alpha", "--decl", "--files"]) == line)
        #expect(Self.refusal(["Alpha", "--decl"]) == nil)
    }

    @Test
    func theCommandLineWiresTheFlagThroughToThePointerAnswer() async throws {
        let root = try MCPTestRepo.make()
        try MCPTestRepo.add(["Sources/App/Alpha.swift": "struct Alpha {\n    func run() {}\n}\n"], to: root)
        let registry = try RootsRegistry(fileURL: TemporaryDirectory.make("roots").appendingPathComponent("roots.json"))
        let answer = try await WhereCommand.parse(["Alpha", "--decl", "--root", root.path]).answer(registry: registry)

        #expect(answer.split(separator: "\n").last?.hasPrefix("`where Alpha` ") == true, "\(answer)")
        #expect(answer.hasSuffix("covers its uses, extensions, conformers, callers and overrides."), "\(answer)")
    }
}
