//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A type served as source keeps the doc comment above it: the one paragraph that says what the type is.
@Suite(.temporaryDirectories)
struct SourcePassthroughDocCommentTests {
    private static let documented = ("Sources/Alpha/Documented.swift", """
    //
    // Copyright © Agulhas Labs
    //

    import Foundation

    /// Names the thing the rest of this file leans on.
    ///
    /// Without this paragraph a reader cannot tell what the type is for.
    @MainActor
    struct Documented {
        let flag: Bool
        let count: Int

        func toggled() -> Bool {
            !flag
        }
    }
    """)

    private static func render(_ target: String, sources: [(String, String)]) throws -> String {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let parsed = try sources.map { try TestSources.parsed($1, path: $0, in: root) }
        try store.replaceFiles(parsed) { _ in ("Alpha", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
        return try renderer.measured(target: target, options: DigestOptions()).text
    }

    @Test
    func aServedDeclarationKeepsItsDocCommentAndAttributes() throws {
        let output = try Self.render("Documented", sources: [Self.documented])

        #expect(output.contains("declaration's source follows)"))
        #expect(output.contains("/// Names the thing the rest of this file leans on."))
        #expect(output.contains("/// Without this paragraph a reader cannot tell what the type is for."))
        #expect(output.contains("@MainActor\nstruct Documented {"))
        // The file's header and imports are not the declaration's, so they stay out.
        #expect(!output.contains("import Foundation"))
        #expect(!output.contains("so the source itself follows"))
    }

    @Test
    func theLeadingLinesStopAtABlankLineOrAPlainComment() {
        let lines = ["// header", "", "// plain", "/// doc", "@Attr", "struct S {}"]

        #expect(SourcePassthrough.leadingLines(above: 6, in: lines) == ["/// doc", "@Attr"])
        #expect(SourcePassthrough.leadingLines(above: 1, in: lines).isEmpty)
    }

    @Test
    func aBlockDocCommentIsKeptWholeAndAPlainBlockCommentIsNot() {
        let doc = ["x", "/**", " * What it is.", " */", "struct S {}"]
        let plain = ["x", "/*", " * Not documentation.", " */", "struct S {}"]

        #expect(SourcePassthrough.leadingLines(above: 5, in: doc) == ["/**", " * What it is.", " */"])
        #expect(SourcePassthrough.leadingLines(above: 5, in: plain).isEmpty)
    }
}
