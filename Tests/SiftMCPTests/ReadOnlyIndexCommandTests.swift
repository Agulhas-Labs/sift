//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// `index` and `reconcile` in a tree nobody may write refuse in one line rather than build an index in memory, throw it away and report it done.
@Suite(.temporaryDirectories)
struct ReadOnlyIndexCommandTests {
    @Test
    func indexAndReconcileRefuseInATreeNobodyMayWrite() async throws {
        let repository = try MCPTestRepo.make()
        let registry = try RootsRegistry(fileURL: TemporaryDirectory.make("roots").appendingPathComponent("roots.json"))
        try Self.chmod("a-w", repository)
        defer { try? Self.chmod("a+w", repository) }

        let index = await #expect(throws: EngineError.self) {
            try await IndexCommand.parse(["--root", repository.path]).run(registry: registry)
        }
        let reconcile = await #expect(throws: EngineError.self) {
            try await ReconcileCommand.parse(["--root", repository.path]).run(registry: registry)
        }

        #expect(!FileManager.default.fileExists(atPath: SiftPaths.cache(in: repository).path))
        for refusal in [index, reconcile].map({ $0.map(String.init(describing:)) ?? "" }) {
            #expect(refusal.contains("cannot be written, so there is no stored index to build or reconcile"), "\(refusal)")
            #expect(!refusal.contains("\n"), "\(refusal)")
        }
    }

    /// `chmod -R <mode>` over `root`.
    private static func chmod(_ mode: String, _ root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["-R", mode, root.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
