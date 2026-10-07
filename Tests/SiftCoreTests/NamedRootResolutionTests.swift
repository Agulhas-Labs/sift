//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A root the caller named is the tree the answer is about: an indexed repository elsewhere on the machine never stands in for it.
@Suite(.temporaryDirectories)
struct NamedRootResolutionTests {
    private static func makeRegistry() throws -> RootsRegistry {
        try RootsRegistry(fileURL: TestSources.makeTempDirectory().appendingPathComponent("roots.json"))
    }

    private static func makeIndexedRepo(declaring type: String, at root: URL? = nil, in registry: RootsRegistry) async throws -> URL {
        let repo = try root.map { try TestSources.makeTempRepo(at: $0) } ?? TestSources.makeTempRepo()
        try TestSources.write("public struct \(type) { public let value: Int }", to: "Sources/Lib/\(type).swift", in: repo)
        try TestSources.commitAll(in: repo, message: "seed")
        try await SiftEngine(directory: repo, registry: registry).ensureFresh()
        return repo
    }

    /// The registry knows `Depot`, so an unnamed directory may adopt it; a folder the caller named must be refused by name instead.
    @Test
    func aNamedFolderThatIsNoWorkTreeIsRefusedRatherThanAnsweredFromAnotherRoot() async throws {
        let registry = try Self.makeRegistry()
        _ = try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        let plain = try TestSources.makeTempDirectory()

        do {
            _ = try RootResolver.resolve(directory: plain, registry: registry, probing: "Depot", namedExplicitly: true)
            Issue.record("a named folder that is no git work tree resolved to another root")
        } catch {
            let message = String(describing: error)
            #expect(message.contains(plain.standardizedFileURL.path))
            #expect(message.contains("not a git work tree"))
            #expect(!message.contains("\n"))
        }
    }

    /// The same folder, unnamed, keeps adopting: the portfolio session is the case adoption exists for.
    @Test
    func anUnnamedFolderStillAdoptsTheRootDeclaringTheName() async throws {
        let registry = try Self.makeRegistry()
        let declaring = try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        let plain = try TestSources.makeTempDirectory()

        let resolved = try RootResolver.resolve(directory: plain, registry: registry, probing: "Depot")

        #expect(resolved.url.standardizedFileURL == declaring.standardizedFileURL)
    }

    /// A named container folder is still answered from the repository under it; one elsewhere does not count.
    @Test
    func aNamedContainerStillResolvesToTheRepositoryUnderIt() async throws {
        let registry = try Self.makeRegistry()
        let container = try TestSources.makeTempDirectory().resolvingSymlinksInPath()
        let inside = try await Self.makeIndexedRepo(declaring: "Depot", at: container.appendingPathComponent("app"), in: registry)
        _ = try await Self.makeIndexedRepo(declaring: "Depot", in: registry)

        let resolved = try RootResolver.resolve(directory: container, registry: registry, probing: "Depot", namedExplicitly: true)

        #expect(resolved.url.standardizedFileURL == inside.standardizedFileURL)
    }
}
