//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A file target spelled from where the caller stands, or as an absolute path, reaches the file under the root a query names, and a path written from the root itself still does.
@Suite(.temporaryDirectories)
struct DigestCurrentDirectoryPathTests {
    private static var source: String {
        "struct Gizmo {\n    func spin() -> Int { 1 }\n}\n"
    }

    /// A renderer over a repository one directory below a parent, with the current directory chosen from that parent and the root.
    private static func renderer(currentDirectory: (_ parent: URL, _ root: URL) -> URL = { parent, _ in parent }) throws -> (renderer: DigestRenderer, root: URL) {
        let parent = try TestSources.makeTempDirectory()
        let root = parent.appendingPathComponent("Depot")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try TestSources.makeStore()
        let parsed = try TestSources.parsed(source, path: "Sources/Alpha/Gizmo.swift", in: root)
        try store.replaceFiles([parsed]) { _ in ("Alpha", false) }
        var renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
        renderer.currentDirectory = currentDirectory(parent, root)
        return (renderer, root)
    }

    private static func assertServed(_ answer: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!answer.contains("no indexed file matches"), sourceLocation: sourceLocation)
        #expect(answer.contains("Gizmo"), sourceLocation: sourceLocation)
    }

    @Test
    func aPathRelativeToTheCurrentDirectoryIsServed() throws {
        let (renderer, _) = try Self.renderer()

        let whole = try renderer.render(target: "Depot/Sources/Alpha/Gizmo.swift", options: DigestOptions())
        let ranged = try renderer.render(target: "Depot/Sources/Alpha/Gizmo.swift:1-3", options: DigestOptions())

        Self.assertServed(whole)
        Self.assertServed(ranged)
    }

    @Test
    func aCurrentDirectoryReachedThroughAnAliasIsServed() throws {
        let (renderer, _) = try Self.renderer { parent, _ in URL(fileURLWithPath: CanonicalPath.of(parent.path)) }

        let answer = try renderer.render(target: "Depot/Sources/Alpha/Gizmo.swift:1-3", options: DigestOptions())

        Self.assertServed(answer)
    }

    @Test
    func anAbsolutePathUnderTheRootIsServed() throws {
        let (renderer, root) = try Self.renderer()

        let answer = try renderer.render(target: root.path + "/Sources/Alpha/Gizmo.swift:1-3", options: DigestOptions())

        Self.assertServed(answer)
    }

    @Test
    func aPathRelativeToTheRootStillWinsFromADirectoryInsideIt() throws {
        let (renderer, _) = try Self.renderer { _, root in root.appendingPathComponent("Sources") }

        let answer = try renderer.render(target: "Sources/Alpha/Gizmo.swift:1-3", options: DigestOptions())

        Self.assertServed(answer)
    }

    @Test
    func aPathOutsideTheRootStaysAMiss() throws {
        let (renderer, _) = try Self.renderer()

        let answer = try renderer.render(target: "Elsewhere/Sources/Alpha/Cog.swift", options: DigestOptions())

        #expect(answer.contains("no indexed file matches"))
    }

    /// An engine's renderer over a repository whose current directory is its `Sources` folder.
    private static func renderer(insideRootOf engine: SiftEngine) throws -> DigestRenderer {
        var renderer = try engine.makeDigestRenderer()
        renderer.currentDirectory = engine.repoRoot.appendingPathComponent("Sources")
        return renderer
    }

    @Test
    func aMarkdownFileNamedFromTheRootIsServedFromADirectoryInsideIt() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.source, to: "Sources/Alpha/Gizmo.swift", in: root)
        try TestSources.write("# Handbook\n\nBody.\n", to: "Docs/Notes.md", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        let renderer = try Self.renderer(insideRootOf: engine)

        let answer = try renderer.render(target: "Docs/Notes.md", options: DigestOptions())

        #expect(!answer.contains("no Markdown file"))
        #expect(answer.contains("Handbook"))
    }

    @Test
    func anExcludedFileNamedFromTheRootIsNotServedAsAnotherFile() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.source, to: "Sources/Lib/Widget.swift", in: root)
        try TestSources.write("Generated/\n", to: ".gitignore", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try TestSources.write("struct Cog {}\n", to: "Generated/Widget.swift", in: root)
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        let renderer = try Self.renderer(insideRootOf: engine)

        let answer = try renderer.render(target: "Generated/Widget.swift", options: DigestOptions())

        #expect(answer.contains("Generated/Widget.swift exists but is not indexed"))
        #expect(!answer.contains("Sources/Lib/Widget.swift"))
    }
}
